#! /usr/bin/env python3
"""T03 regression suite: normalized contracts and capability profiles.

Scenarios (task card):
 - normative links resolve and every authority blob sha matches the recorded
   value (exact-SHA evidence links)
 - generated constants stay frozen: independent reference self-checks and the
   canonical wire codegen selftest pass
 - release graph remains Archive-only (ci/check_release_gates_status.py)
 - unsupported background directions appear as recorded limitations
 - the superseded role matrix says so at the top
 - ACK comment sites are corrected (8-byte magic, 40-byte preimage) while the
   executable bytes are untouched
 - cipher suite stays BLAKE2s; ADR-007 stays OPEN/PROPOSED

Mutations (task card; corrupted copies in a temp dir - pure tooling):
 - election rewritten to platform-based -> invariant validation fails
 - LIGHT mesh marked available -> profile validation fails
 - readiness flipped to true -> both validators fail
 - PROPOSED approval language dropped -> validation fails
 - recorded authority blob substituted with a foreign sha -> rejected
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.dirname(HERE)
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)
import run  # noqa: E402
import contract_check  # noqa: E402

REPO = os.environ.get('GODSTONE_BUILDER_ROOT',
                      os.path.dirname(os.path.dirname(TOOLS_DIR)))
DR = os.path.join(REPO, 'docs', 'production-readiness')
INVARIANTS = os.path.join(DR, 'ARCHITECTURE_INVARIANTS.json')
PROFILES = os.path.join(DR, 'CAPABILITY_PROFILES.json')


def git_blob(path):
    proc = subprocess.run(['git', 'hash-object', path], cwd=REPO,
                          capture_output=True, text=True)
    return proc.stdout.strip()


class ReadinessTestCase(unittest.TestCase):
    """Shared assertion vocabulary for the readiness suite."""

    def assertEmpty(self, seq, msg=None):
        self.assertEqual(list(seq), [], msg=msg)

    def assertNotEmpty(self, seq, msg=None):
        self.assertNotEqual(list(seq), [], msg=msg)

    def assertPathExists(self, path, msg=None):
        self.assertTrue(os.path.isfile(path),
                        msg=msg or f'missing file: {path}')


class SourceIntegrityTest(ReadinessTestCase):
    """L0 source-integrity checks for a documentation/control change."""

    def test_readiness_constants_are_false(self):
        kt = open(os.path.join(REPO, 'android/mesh/src/main/java/io/godstone/'
                               'mesh/transport/BleTransport.kt'),
                  encoding='utf-8').read()
        swift = open(os.path.join(REPO,
                                  'ios/Godstone/Sources/GodstoneMesh/'
                                  'MeshNode.swift'),
                     encoding='utf-8').read()
        self.assertIn('LINK_LAYER_READY = false', kt)
        self.assertIn('linkLayerReady = false', swift)

    def test_ack_preimage_comment_sites(self):
        sites = ('ios/Godstone/Sources/GodstoneMesh/AckAuthenticator.swift',
                 'android/mesh/src/main/java/io/godstone/mesh/delivery/'
                 'AckAuthenticator.kt')
        for rel in sites:
            text = open(os.path.join(REPO, rel), encoding='utf-8').read()
            with self.subTest(site=rel):
                self.assertIn('40 bytes', text)
                self.assertNotIn('39 bytes', text)
                self.assertIn('ACK_MAGIC("GMP2-ACK", 8)', text)
                self.assertNotIn('ACK_MAGIC("GMP2-ACK", 7)', text)
        self.assertEqual(len('GMP2-ACK'), 8)
        adr5 = open(os.path.join(REPO, 'docs/adr/ADR-005-sos-and-lifecycle.md'),
                    encoding='utf-8').read()
        self.assertIn('(8 ASCII)', adr5)
        self.assertNotIn('(7 ASCII)', adr5)

    def test_canonical_and_generated_ack_files_in_sync(self):
        canonical = os.path.join(
            REPO, 'ios/Godstone/Sources/GodstoneMesh/AckAuthenticator.swift')
        generated = os.path.join(
            REPO, 'ios/Packages/GodstoneFoundation/Sources/GodstoneMesh/'
            'AckAuthenticator.swift')
        import hashlib
        h1 = hashlib.sha256(open(canonical, 'rb').read()).hexdigest()
        h2 = hashlib.sha256(open(generated, 'rb').read()).hexdigest()
        self.assertEqual(h1, h2, msg='canonical/generated drift detected')


class GeneratedConstantsTest(ReadinessTestCase):
    """The independent references and the codegen selftest must stay green."""

    def _run(self, argv):
        proc = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                              timeout=120)
        return proc.returncode, (proc.stdout or '') + (proc.stderr or '')

    def test_ble_record_reference_frozen(self):
        code, output = self._run(['python3', 'wire/ble_record_reference.py',
                                  '--check'])
        self.assertEqual(code, 0, msg=output[-400:])

    def test_linkinfo_reference_frozen(self):
        code, output = self._run(['python3', 'wire/ble_link_info_reference.py',
                                  '--check'])
        self.assertEqual(code, 0, msg=output[-400:])

    def test_wire_codegen_selftest(self):
        code, output = self._run(['python3', '-m', 'wire.codegen', '--selftest'])
        self.assertEqual(code, 0, msg=output[-400:])

    def test_shipping_graph_archive_only(self):
        code, output = self._run(['python3', 'ci/check_release_gates_status.py'])
        self.assertEqual(code, 0, msg=output[-400:])


class ContractDocumentTest(ReadinessTestCase):

    def test_authority_blobs_match_recorded_shas(self):
        doc = json.load(open(INVARIANTS, encoding='utf-8'))
        checked = 0
        for entry in doc['entries']:
            for ref in entry.get('authority_paths', []):
                full = os.path.join(REPO, ref['path'])
                with self.subTest(authority=ref['path']):
                    self.assertPathExists(full)
                    self.assertEqual(git_blob(full), ref['blob_sha1'],
                                     msg=f'blob drift for {ref["path"]}')
                    checked += 1
        self.assertGreater(checked, 0)

    def test_profiles_match_shipping_exclusions(self):
        doc = json.load(open(PROFILES, encoding='utf-8'))
        light = doc['profiles']['LIGHT']
        self.assertTrue(light['shipping'])
        self.assertTrue(light['archive'])
        for feature in ('mesh', 'oracle', 'sos', 'bulk'):
            self.assertIs(light[feature], False)
        self.assertIs(light['readiness']['android'], False)
        self.assertIs(light['readiness']['ios'], False)
        self.assertIn('LIGHT_ARCHIVE_ONLY',
                     json.load(open(INVARIANTS, encoding='utf-8'))
                     ['shipping_profile'])

    def test_election_is_frozen_not_platform_based(self):
        profiles = json.load(open(PROFILES, encoding='utf-8'))
        rule = profiles['election']['rule']
        self.assertIn('unsigned-lexicographic', rule)
        self.assertIn('fails closed', rule)
        self.assertNotIn('platform-based', rule)
        self.assertEqual(profiles['election']['status'], 'FROZEN')

    def test_background_limitations_are_recorded(self):
        doc = json.load(open(PROFILES, encoding='utf-8'))
        limitations = ' '.join(doc['limitations'])
        self.assertIn('overflow area', limitations)
        self.assertIn('structurally impossible', limitations)
        self.assertIn('HARDWARE gate open', limitations)

    def test_role_matrix_marked_superseded(self):
        text = open(os.path.join(REPO, 'transport/ROLE_MATRIX.md'),
                    encoding='utf-8').read()
        head = text[:600]
        self.assertIn('SUPERSEDED', head)
        self.assertIn('ADR-002-ble-record-layer.md', head)
        self.assertIn('CAPABILITY_PROFILES.json', head)

    def test_cipher_suite_not_approved(self):
        adr7 = open(os.path.join(REPO, 'docs/adr/ADR-007-cipher-suite.md'),
                    encoding='utf-8').read()
        self.assertIn('STATUS: OPEN', adr7)
        invariants = json.load(open(INVARIANTS, encoding='utf-8'))
        self.assertIn('BLAKE2s', invariants['noise']['suite'])
        proposed = [e for e in invariants['entries']
                    if e['status'] == 'PROPOSED']
        self.assertGreaterEqual(len(proposed), 4)
        for entry in proposed:
            self.assertIn('not approved', entry['statement'])


class MutationControlTest(ReadinessTestCase):
    """Corrupted copies must fail validation - the card's mutation set."""

    def _mutated(self, tmp, source, mutate):
        doc = json.load(open(source, encoding='utf-8'))
        mutate(doc)
        target = os.path.join(tmp, os.path.basename(source))
        with open(target, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(doc, sort_keys=True, indent=2))
        return target

    def test_platform_election_mutation_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = self._mutated(
                tmp, INVARIANTS,
                lambda d: d['link_info'].update(
                    election='platform-based lowest node_hint election, '
                             'capped at 3 anchors'))
            problems = contract_check.validate_invariants(REPO, target)
            self.assertTrue(any('platform-based election is rejected' in p
                               for p in problems), msg=problems)

    def test_disabled_feature_marked_available_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = self._mutated(
                tmp, PROFILES,
                lambda d: d['profiles']['LIGHT'].update(mesh=True))
            problems = contract_check.validate_profiles(REPO, target)
            self.assertTrue(any('disabled feature' in p and 'mesh' in p
                               for p in problems), msg=problems)

    def test_readiness_flip_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = self._mutated(
                tmp, INVARIANTS,
                lambda d: d['readiness'].update(android_LINK_LAYER_READY=True))
            problems = contract_check.validate_invariants(REPO, target)
            self.assertTrue(any('must be false' in p for p in problems),
                            msg=problems)

    def test_silent_approval_of_proposed_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = json.load(open(INVARIANTS, encoding='utf-8'))
            changed = 0
            for entry in doc['entries']:
                if entry['status'] == 'PROPOSED':
                    entry['statement'] = entry['statement'].replace(
                        'not approved', 'accepted by the builder')
                    changed += 1
            self.assertGreaterEqual(changed, 1)
            target = os.path.join(tmp, 'invariants.json')
            with open(target, 'w', encoding='utf-8') as stream:
                stream.write(json.dumps(doc, sort_keys=True, indent=2))
            problems = contract_check.validate_invariants(REPO, target)
            self.assertTrue(any('must state they are not approved' in p
                               for p in problems), msg=problems)


        with tempfile.TemporaryDirectory() as tmp:
            doc = json.load(open(INVARIANTS, encoding='utf-8'))
            doc['entries'][0]['authority_paths'][0]['blob_sha1'] = 'f' * 40
            target = os.path.join(tmp, 'invariants.json')
            with open(target, 'w', encoding='utf-8') as stream:
                stream.write(json.dumps(doc, sort_keys=True, indent=2))
            problems = contract_check.validate_invariants(REPO, target)
            self.assertTrue(any('authority blob drift' in p for p in problems),
                            msg=problems)

    def test_future_schema_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = self._mutated(
                tmp, INVARIANTS, lambda d: d.update(schema_version=99))
            with self.assertRaises(run.StateInvalid):
                run.load_json_strict(target)



if globals().get('__name__') == '__main__':
    unittest.main(verbosity=2)