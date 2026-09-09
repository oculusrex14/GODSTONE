#! /usr/bin/env python3
"""T04 regression suite: the ExternalNoiseLockV1 structural gate.

Required scenarios (task card):
 - missing lock -> typed UNAVAILABLE with a nonzero release exit
 - one-byte fixture mutation -> FAILED (invalid digest)
 - wrong prologue / wrong suite recorded in the lock -> FAILED
 - incomplete case list (partial selection) -> FAILED
 - invalid digest -> FAILED
 - duplicate case ids -> FAILED
 - self-generated fixture mislabeled independent -> FAILED

Mutation (task card):
 - bypass source-hash verification while keeping symbols unchanged: the
   mutant must fail to detect a warning-text fixture mutation (only the
   digest check stands in the way of that change) while the real module
   rejects it - which is how the executable lock tests kill the mutant

Every fixture used here is SELF-GENERATED and honestly labeled; none of them
may be committed as the real A-06 fixture, and the gate stays open.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.dirname(HERE)
BUILDER = os.path.dirname(os.path.dirname(TOOLS_DIR))
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

REPO = os.environ.get('GODSTONE_BUILDER_ROOT', BUILDER)
sys.path.insert(0, REPO)

from crypto import noise_lock  # noqa: E402
from crypto.cacophony import TARGET  # noqa: E402
from crypto.noise_ref import run_vector  # noqa: E402

FAKE_ORIGIN = 'https://example.invalid/independent-noise-vectors'
FAKE_REVISION = 'a' * 40


def _synth(directory, prologue=None):
    """Build an honestly-labeled self-generated vector fixture."""
    prologue = prologue or (b'GMP2' + bytes([0x01]) * 4 + bytes([0x02]) * 4)
    i_s, i_e = bytes([0xA1]) * 32, bytes([0xA2]) * 32
    r_s, r_e = bytes([0xB1]) * 32, bytes([0xB2]) * 32
    payloads = [b'', b'', b'', b'transport-one', b'transport-two']
    out = run_vector(i_s, i_e, r_s, r_e, prologue, payloads)
    fixture = {'_warning': 'SELF-GENERATED; machinery test only',
               'vectors': [{
                   'protocol_name': TARGET,
                   'init_prologue': prologue.hex(),
                   'resp_prologue': prologue.hex(),
                   'init_static': i_s.hex(),
                   'init_ephemeral': i_e.hex(),
                   'resp_static': r_s.hex(),
                   'resp_ephemeral': r_e.hex(),
                   'handshake_hash': out['handshake_hash'],
                   'messages': [{'payload': p.hex(), 'ciphertext': c}
                                for p, c in zip(payloads, out['messages'])],
               }]}
    path = os.path.join(directory, 'synthetic_vectors.json')
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write(json.dumps(fixture, indent=2) + '\n')
    return path, prologue


def _make_parts(directory, mutate_lock=None, mutate_fixture=None,
                prologue=None):
    """Create a consistent synthetic lock+fixture pair, then apply mutations."""
    fixture_path, prologue = _synth(directory, prologue)
    # the lock pins the HONEST fixture; any later tampering must be
    # detected as a digest mismatch, never absorbed into the pin
    original_digest = noise_lock.sha256_file(fixture_path)
    if mutate_fixture is not None:
        doc = json.load(open(fixture_path, encoding='utf-8'))
        mutate_fixture(doc)
        with open(fixture_path, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(doc, indent=2) + '\n')
    digest = original_digest
    lock = {
        'lock_schema': 'ExternalNoiseLockV1',
        'upstream': {'repo': FAKE_ORIGIN, 'revision': FAKE_REVISION,
                     'path': 'vectors/cacophony.txt',
                     'fetched_utc': '2026-09-09T00:00:00Z'},
        'license': 'CC0-1.0 (machinery test only)',
        'source_sha256': digest,
        'fixture_sha256': digest,
        'protocol_name': TARGET,
        'prologue_sha256': hashlib.sha256(prologue).hexdigest(),
        'prologue_prefix_hex': b'GMP2'.hex(),
        'required_cases': [f'{TARGET}@0'],
        'reviewer': {'identity': 'A-06 machinery-test reviewer',
                     'date': '2026-09-09'},
    }
    if mutate_lock is not None:
        mutate_lock(lock)
    lock_path = os.path.join(directory, 'noise_lock.json')
    with open(lock_path, 'w', encoding='utf-8') as stream:
        stream.write(json.dumps(lock, indent=2) + '\n')
    return lock_path, fixture_path


class ReadinessTestCase(unittest.TestCase):
    """Shared assertion vocabulary for the readiness suite."""

    def assertEmpty(self, seq, msg=None):
        self.assertEqual(list(seq), [], msg=msg)

    def assertNotEmpty(self, seq, msg=None):
        self.assertNotEqual(list(seq), [], msg=msg)

    def assertPathExists(self, path, msg=None):
        self.assertTrue(os.path.isfile(path), msg=msg or f'missing {path}')


class LockMissingTest(ReadinessTestCase):

    def test_missing_lock_is_typed_unavailable_with_release_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            status_value, problems, _ = noise_lock.verify_lock(
                os.path.join(tmp, 'absent-lock.json'),
                os.path.join(tmp, 'absent-fixture.json'))
            self.assertEqual(status_value,
                             noise_lock.ConformanceStatus.UNAVAILABLE)
            self.assertNotEmpty(problems)
            self.assertIn('no lock file', problems[0])
        absent_lock = os.path.join(tempfile.gettempdir(),
                                   'absent-lock-t04.json')
        absent_fixture = os.path.join(tempfile.gettempdir(),
                                      'absent-fixture-t04.json')
        for path in (absent_lock, absent_fixture):
            if os.path.exists(path):
                os.remove(path)
        proc = subprocess.run(
            [sys.executable, '-m', 'crypto.noise_lock', '--release',
             '--lock', absent_lock, '--fixture', absent_fixture],
            cwd=REPO, capture_output=True, text=True, timeout=120)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(
            proc.returncode,
            noise_lock.EXIT_CODES[noise_lock.ConformanceStatus.UNAVAILABLE])
        self.assertIn('UNAVAILABLE', proc.stdout)

    def test_missing_fixture_is_unavailable_even_with_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            absent = os.path.join(tmp, 'no-such-fixture')
            lock_path, _ = _make_parts(
                tmp, mutate_lock=lambda lock: lock.update(
                    fixture_sha256=noise_lock.sha256_file(absent)
                    if os.path.isfile(absent) else '0' * 64))
            # rewrite the lock to pin the absent fixture digest placeholder
            doc = json.load(open(lock_path, encoding='utf-8'))
            doc['fixture_sha256'] = '0' * 64
            doc['source_sha256'] = '0' * 64
            with open(lock_path, 'w', encoding='utf-8') as stream:
                stream.write(json.dumps(doc, indent=2) + '\n')
            status_value, problems, _ = noise_lock.verify_lock(lock_path,
                                                               absent)
            self.assertEqual(status_value,
                             noise_lock.ConformanceStatus.UNAVAILABLE)


class LockScenariosTest(ReadinessTestCase):
    """All card-required negative scenarios through verify_lock."""

    def _scenario(self, mutate_lock=None, mutate_fixture=None, prologue=None):
        with tempfile.TemporaryDirectory() as tmp:
            lock_path, fixture_path = _make_parts(
                tmp, mutate_lock, mutate_fixture, prologue=prologue)
            return noise_lock.verify_lock(lock_path, fixture_path)

    def test_sound_machinery_lock_verifies(self):
        status_value, problems, detail = self._scenario()
        self.assertEqual(status_value, noise_lock.ConformanceStatus.VERIFIED,
                         msg=problems)
        self.assertIn('verified', detail)

    def test_one_byte_ciphertext_mutation_is_rejected(self):
        def flip_first_ciphertext_byte(doc):
            ciphertext = doc['vectors'][0]['messages'][0]['ciphertext']
            replacement = 'ff' if not ciphertext.startswith('ff') else '00'
            doc['vectors'][0]['messages'][0]['ciphertext'] = \
                replacement + ciphertext[2:]
        status_value, problems, _ = self._scenario(
            mutate_fixture=flip_first_ciphertext_byte)
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(
            any('digest mismatch' in p or 'did not reproduce' in p
                for p in problems), msg=problems)

    def test_warning_text_mutation_is_caught_by_digest(self):
        def append_marker(doc):
            doc['_warning'] = doc['_warning'] + ' tampered'
        status_value, problems, _ = self._scenario(
            mutate_fixture=append_marker)
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('digest mismatch' in p for p in problems),
                        msg=problems)

    def test_wrong_prologue_digest_is_rejected(self):
        status_value, problems, _ = self._scenario(
            mutate_lock=lambda lock: lock.update(
                prologue_sha256=hashlib.sha256(b'OTHER-PROLOGUE').hexdigest()))
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('prologue digest mismatch' in p for p in problems),
                        msg=problems)

    def test_wrong_prologue_prefix_is_rejected(self):
        status_value, problems, _ = self._scenario(
            mutate_lock=lambda lock: lock.update(
                prologue_prefix_hex=b'NOISE'.hex()))
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('GMP2 prefix' in p for p in problems),
                        msg=problems)

    def test_wrong_suite_is_rejected(self):
        status_value, problems, _ = self._scenario(
            mutate_lock=lambda lock: lock.update(
                protocol_name='Noise_XX_25519_ChaChaPoly_SHA256'))
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('different protocol suite' in p for p in problems),
                        msg=problems)

    def test_partial_case_selection_is_rejected(self):
        status_value, problems, _ = self._scenario(
            mutate_lock=lambda lock: lock.update(required_cases=[]))
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('partial selection' in p for p in problems),
                        msg=problems)

    def test_duplicate_case_ids_are_rejected(self):
        def mutate(lock):
            case = lock['required_cases'][0]
            lock['required_cases'] = [case, case]
        status_value, problems, _ = self._scenario(mutate_lock=mutate)
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('partial selection' in p or 'duplicate' in p
                           for p in problems), msg=problems)

    def test_invalid_fixture_digest_is_rejected(self):
        status_value, problems, _ = self._scenario(
            mutate_lock=lambda lock: lock.update(fixture_sha256='0' * 64))
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('digest mismatch' in p for p in problems),
                        msg=problems)

    def test_self_origin_is_refused(self):
        def mutate(lock):
            lock['upstream']['repo'] = \
                'https://github.com/oculusrex14/godstone-fixture'
        status_value, problems, _ = self._scenario(mutate_lock=mutate)
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('mislabeled independent' in p for p in problems),
                        msg=problems)

    def test_missing_reviewer_is_rejected(self):
        status_value, problems, _ = self._scenario(
            mutate_lock=lambda lock: lock.update(reviewer={'identity': '',
                                                           'date': ''}))
        self.assertEqual(status_value, noise_lock.ConformanceStatus.FAILED)
        self.assertTrue(any('reviewer.identity' in p for p in problems),
                        msg=problems)

    def test_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock = os.path.join(tmp, 'noise_lock.json')
            with open(lock, 'w', encoding='utf-8') as stream:
                stream.write('{"lock_schema": "ExternalNoiseLockV1", '
                             '"lock_schema": "other"}')
            status_value, problems, _ = noise_lock.verify_lock(
                lock, os.path.join(tmp, 'no-fixture'))
            self.assertEqual(status_value,
                             noise_lock.ConformanceStatus.FAILED)
            self.assertTrue(any('duplicate key' in p for p in problems),
                            msg=problems)


class HarnessPlumbingTest(ReadinessTestCase):

    def test_cacophony_selftest_plumbing_positive(self):
        proc = subprocess.run(
            [sys.executable, '-m', 'crypto.cacophony', '--selftest'],
            cwd=REPO, capture_output=True, text=True, timeout=300)
        self.assertEqual(proc.returncode, 0,
                         msg=(proc.stdout + proc.stderr)[-400:])

    def test_repository_fixture_stays_unpinned(self):
        proc = subprocess.run(
            [sys.executable, '-m', 'crypto.noise_lock', '--status'],
            cwd=REPO, capture_output=True, text=True, timeout=120)
        self.assertEqual(proc.returncode, 0)
        self.assertIn('UNAVAILABLE', proc.stdout)

    def test_conformance_suite_reports_typed_lock_status(self):
        proc = subprocess.run(
            [sys.executable, '-m', 'crypto.test_conformance'],
            cwd=REPO, capture_output=True, text=True, timeout=600)
        self.assertEqual(proc.returncode, 0)
        self.assertIn('ExternalNoiseLockV1: UNAVAILABLE', proc.stdout)
        self.assertIn('checks=', proc.stdout)


class MutationControlTest(ReadinessTestCase):
    """Bypass the digest check, keep symbols: the mutant must be caught.

    The tampering here edits only the honestly-labeled warning text: the
    vector bytes still reproduce, so the ONLY remaining defense is the
    fixture digest. The real module must reject; the bypassed mutant must
    not - and that contrast is the mutation verdict.
    """

    def test_hash_bypass_mutant_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            pkg = os.path.join(tmp, 'crypto')
            shutil.copytree(os.path.join(REPO, 'crypto'), pkg,
                            ignore=shutil.ignore_patterns(
                                '__pycache__', '*.pyc'))
            module_path = os.path.join(pkg, 'noise_lock.py')
            src = open(module_path, encoding='utf-8').read()
            needle = "    if lock.get('fixture_sha256') != fixture_sha:"
            self.assertEqual(src.count(needle), 1)
            open(module_path, 'w', encoding='utf-8').write(
                src.replace(needle, '    if False:', 1))
            case_dir = os.path.join(tmp, 'case')
            os.makedirs(case_dir, exist_ok=True)
            lock_path, fixture_path = _make_parts(case_dir)
            doc = json.load(open(fixture_path, encoding='utf-8'))
            doc['_warning'] = doc['_warning'] + ' tampered'
            with open(fixture_path, 'w', encoding='utf-8') as stream:
                stream.write(json.dumps(doc, indent=2) + '\n')
            runner = (
                'import sys; sys.path.insert(0, {tmp!r});'
                'from crypto import noise_lock as m;'
                'print(m.verify_lock({lock!r}, {fixture!r})[0])'
            ).format(tmp=tmp, lock=lock_path, fixture=fixture_path)
            mutant_proc = subprocess.run(
                [sys.executable, '-c', runner], capture_output=True,
                text=True, timeout=180)
            real_status, real_problems, _ = noise_lock.verify_lock(
                lock_path, fixture_path)
            self.assertEqual(real_status,
                             noise_lock.ConformanceStatus.FAILED,
                             msg=real_problems)
            self.assertIn('digest mismatch', ' '.join(real_problems))
            self.assertIn('VERIFIED', mutant_proc.stdout,
                          msg='mutant did not bypass the digest check: '
                          f'{mutant_proc.stdout} {mutant_proc.stderr}')
            # the mutant is defective exactly because it loses the rejection
            # the real module keeps; recording the contrast is the verdict
            self.assertNotEqual(real_status, 'VERIFIED')


if globals().get('__name__') == '__main__':
    unittest.main(verbosity=2)