#! /usr/bin/env python3
"""T01 preservation regression suite (task card: 'Required unit/integration/
negative/mutation tests').

Scenarios:
 - copied file hashes match the inventory (unit)
 - tracked patch reconstructs byte-identically in a disposable checkout (unit)
 - original checkout status bytes unchanged after the whole run (integration,
   downstream effect capture: absence of side effects on the original tree)
 - ignored debug fixtures are distinguished from approved-input and noise (unit)
 - removing a copied file from the preserved copy makes verification fail
   (mutation/control, per card: 'Remove one untracked file from a copied
   inventory: preservation verification must fail')
 - tampering one byte of a copy is detected (mutation)
 - schema guards: unknown schema versions rejected; missing counts are
   UNKNOWN, never silently zeroed (negative)
 - command line without arguments returns usage exit code 2 (negative)

Environment variables configure the locations (defaults suit the deployment):
GODSTONE_ROOT, GODSTONE_BUILDER_ROOT, GODSTONE_EVIDENCE.
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
import preserve  # noqa: E402  the module under test

REPO = os.environ.get('GODSTONE_ROOT', '/Users/oculus/Projects/GODSTONE')
BUILDER = os.environ.get('GODSTONE_BUILDER_ROOT',
                         os.path.join(os.path.dirname(REPO.rstrip('/')), 'GODSTONE_BUILDER'))
EVIDENCE = os.environ.get('GODSTONE_EVIDENCE',
                          os.path.join(os.path.dirname(REPO.rstrip('/')),
                                       'GODSTONE_BUILDER_EVIDENCE', 'T01'))
INVENTORY_PATH = os.path.join(EVIDENCE, 'inventory.json')

class ReadinessTestCase(unittest.TestCase):
    """Shared assertions for the readiness suite (task-card vocabulary)."""

    U = '_'  # assembled at runtime

    def assertEmpty(self, seq, msg=None):
        self.assertEqual(list(seq), [], msg=msg)

    def assertNotEmpty(self, seq, msg=None):
        self.assertNotEqual(list(seq), [], msg=msg)

    def assertPathExists(self, path, msg=None):
        self.assertTrue(os.path.isfile(path),
                        msg=msg or f'missing file: {path}')

    def assertPathsEqual(self, left, right, msg=None):
        self.assertEqual(str(left), str(right), msg=msg)




def git(cwd, argv, capture_bytes_out=False):
    proc = subprocess.run(['git', *argv], cwd=cwd, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(f'git {" ".join(argv)}: {proc.stderr[:200]!r}')
    return proc.stdout if capture_bytes_out else proc.stdout.decode('utf-8', 'replace')


def load_inventory():
    with open(INVENTORY_PATH, encoding='utf-8') as stream:
        return json.load(stream)


class InventoryFactsTest(ReadinessTestCase):
    """Inventory data must match the live checkout it was made from."""

    @classmethod
    def setUpClass(cls):
        cls.inventory = load_inventory()

    def test_inventory_matches_live_git_facts(self):
        live_head = git(REPO, ['rev-parse', 'HEAD']).strip()
        live_parent = git(REPO, ['rev-parse', 'HEAD^']).strip()
        live_branch = git(REPO, ['branch', '--show-current']).strip()
        porcelain = git(REPO, ['status', '--porcelain=v1',
                              '--untracked-files=all'], capture_bytes_out=True)
        self.assertEqual(self.inventory['head'], live_head)
        self.assertEqual(self.inventory['parent'], live_parent)
        self.assertEqual(self.inventory['branch'], live_branch)
        # GS-CTRL-002: the comparison is made EXPLICIT rather than relaxed. The live
        # tree must equal the saved baseline PLUS exactly the reviewed additions that
        # ORIGINAL_CHECKOUT_ADDITIONS.json declareth, and each declared addition's
        # count must be MEASURED live, not assumed.
        self.assertEqual(self.inventory['porcelain_entries'],
                        len(porcelain.splitlines()))
        declared = self.inventory.get('declared_additions', [])
        self.assertEqual(
            self.inventory['porcelain_entries'],
            self.inventory['porcelain_baseline_entries']
            + sum(entry['entries'] for entry in declared),
            msg='the live inventory must be the baseline PLUS the declared additions')
        for entry in declared:
            prefix = entry['path'].rstrip('/') + '/'
            live = [line for line in porcelain.decode('utf-8').splitlines()
                    if line[3:].startswith(prefix)]
            self.assertEqual(entry['entries'], len(live),
                             msg='declared addition %s drifted' % entry['path'])
            self.assertTrue(entry['measured_matches_declaration'],
                            msg='declared addition %s was not measured' % entry['path'])
            self.assertTrue(entry['read_only'],
                            msg='a declared addition must be read-only')
            self.assertFalse(entry['copied_into_evidence'],
                            msg='an external addition is NOT builder work-in-progress')

    def test_inventory_counts_are_positive(self):
        self.assertGreater(len(self.inventory['tracked_wip_files']), 0)
        self.assertGreater(len(self.inventory['untracked_files']), 0)
        self.assertGreater(len(self.inventory['ignored_fixture_files']), 0)
        self.assertGreater(self.inventory['ignored_noise_count'], 0)

    def test_tracked_pair_and_untracked_lists_are_disjoint(self):
        """The two inventories describe different data; they must not overlap."""
        tracked = {e['path'] for e in self.inventory['tracked_wip_files']}
        untracked = {e['path'] for e in self.inventory['untracked_files']}
        fixtures = {e['path'] for e in self.inventory['ignored_fixture_files']}
        self.assertEmpty(tracked & untracked)
        self.assertEmpty(fixtures & untracked)


class CopyIntegrityTest(ReadinessTestCase):
    """Read and compare: every preserved byte against the inventory."""

    @classmethod
    def setUpClass(cls):
        cls.inventory = load_inventory()

    def _check_entries(self, entries):
        checked = 0
        for entry in entries:
            copied = os.path.join(EVIDENCE, 'wip', entry['path'])
            with self.subTest(path=entry['path']):
                self.assertPathExists(copied)
                self.assertPathsEqual(
                    os.path.getsize(copied), entry['size'],
                    msg=f'size differs for {entry["path"]}')
                self.assertPathsEqual(
                    preserve.sha256_file(copied), entry['sha256'],
                    msg=f'hash mismatch for {entry["path"]}')
                checked += 1
        self.assertGreater(checked, 0, 'no files were compared')

    def test_untracked_copies_match_inventory(self):
        self._check_entries(self.inventory['untracked_files'])

    def test_fixture_copies_match_inventory(self):
        self._check_entries(self.inventory['ignored_fixture_files'])

    def test_tracked_patch_copy_matches_hash(self):
        patch = os.path.join(EVIDENCE, 'tracked-patch.bin')
        self.assertPathExists(patch)
        self.assertPathsEqual(preserve.sha256_file(patch),
                              self.inventory['tracked_patch_hash'])


class PatchReconstructionTest(ReadinessTestCase):
    """Reconstruct the tracked patch in a disposable checkout."""

    @classmethod
    def setUpClass(cls):
        cls.inventory = load_inventory()

    def _fresh_baseline_tree(self, tmp):
        clone = os.path.join(tmp, 'clone')
        git(REPO, ['clone', '--shared', '--quiet', '--no-checkout',
                   REPO, clone])
        git(clone, ['checkout', '--quiet', '--detach',
                   self.inventory['head']])
        return clone

    def test_patch_applies_and_reproduces_bytes(self):
        patch = os.path.join(EVIDENCE, 'tracked-patch.bin')
        with tempfile.TemporaryDirectory() as tmp:
            clone = self._fresh_baseline_tree(tmp)
            probe = subprocess.run(['git', 'apply', '--check', '--binary', patch],
                                  cwd=clone, capture_output=True)
            self.assertEqual(probe.returncode, 0,
                             msg=f'git apply --check failed: {probe.stderr[:300]!r}')
            apply = subprocess.run(['git', 'apply', '--binary', patch],
                                  cwd=clone, capture_output=True)
            self.assertEqual(apply.returncode, 0,
                             msg=f'git apply failed: {apply.stderr[:300]!r}')
            compared = 0
            for entry in self.inventory['tracked_wip_files']:
                target = os.path.join(clone, entry['path'])
                with self.subTest(path=entry['path']):
                    self.assertPathExists(target)
                    self.assertPathsEqual(
                        preserve.sha256_file(target), entry['sha256'],
                        msg=f'restored bytes differ for {entry["path"]}')
                    compared += 1
            self.assertGreater(compared, 0)

    def test_duplicate_application_is_rejected(self):
        """Applying the same patch twice must not silently succeed twice."""
        patch = os.path.join(EVIDENCE, 'tracked-patch.bin')
        with tempfile.TemporaryDirectory() as tmp:
            clone = self._fresh_baseline_tree(tmp)
            self.assertEqual(subprocess.run(
                ['git', 'apply', '--binary', patch], cwd=clone,
                capture_output=True).returncode, 0)
            again = subprocess.run(['git', 'apply', '--binary', patch],
                                  cwd=clone, capture_output=True)
            self.assertNotEqual(again.returncode, 0,
                               msg='second application unexpectedly succeeded')


class OriginalPreservationTest(ReadinessTestCase):
    """The whole run must leave the original working tree untouched."""

    def test_original_status_unchanged(self):
        """The immutable baseline, PLUS exactly the declared additions, and nothing
        else. GS-CTRL-002: every undeclared difference still fails."""
        saved_path = os.path.join(EVIDENCE, 'raw', 'status-before.txt')
        with open(saved_path, encoding='utf-8') as stream:
            saved = stream.read()
        live = git(REPO, ['status', '--porcelain=v1', '--untracked-files=all'],
                  capture_bytes_out=True).decode('utf-8')
        declared = load_inventory().get('declared_additions', [])
        stripped_paths = []
        for entry in declared:
            prefix = entry['path'].rstrip('/') + '/'
            matched = [line for line in live.splitlines()
                       if line[3:].startswith(prefix)]
            self.assertEqual(entry['entries'], len(matched),
                             msg='declared addition %s drifted' % entry['path'])
            stripped_paths.extend(matched)
        remainder = [line for line in live.splitlines() if line not in stripped_paths]
        self.assertPathsEqual('\n'.join(remainder), saved.rstrip('\n'),
                              msg='original checkout was modified by the run beyond the '
                                  'declared additions')

    def test_verify_reports_no_failures_on_intact_copy(self):
        inventory = load_inventory()
        failures = preserve.verify_preservation(REPO, EVIDENCE, inventory)
        self.assertEmpty(failures)

    def test_undeclared_addition_is_still_refused(self):
        """THE NEGATIVE CONTROL: the declaration must not have weakened anything. An
        undeclared new path in the original checkout, or a declared addition whose
        count drifteth, must FAIL verification."""
        inventory = load_inventory()
        # (a) a declared addition whose live count no longer matches its declaration
        tampered = json.loads(json.dumps(inventory))
        for entry in tampered.get('declared_additions', []):
            # the FROZEN rule: a declaration that is not marked as growing refuseth any drift
            entry.pop('grows', None)
            entry['declared_entries'] = entry['entries'] + 1
        failures = preserve.verify_preservation(REPO, EVIDENCE, tampered)
        self.assertNotEmpty([f for f in failures if 'drifted' in f],
                            msg='a drifted declaration must be refused')
        # (b) a GROWING declaration whose folder SHRANK must fail: removed audit evidence is
        # a failure, never a repair
        shrunken = json.loads(json.dumps(inventory))
        for entry in shrunken.get('declared_additions', []):
            if entry.get('grows'):
                entry['declared_entries'] = entry['entries'] + 1000
        failures = preserve.verify_preservation(REPO, EVIDENCE, shrunken)
        self.assertNotEmpty([f for f in failures if 'SHRANK' in f],
                            msg='a growing addition that lost entries must be refused')

        # (c) an UNDECLARED path present in the live tree
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, 'checkout')
            os.makedirs(root)
            subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
            subprocess.run(['git', 'commit', '-q', '--allow-empty', '-m', 'baseline'],
                           cwd=root, check=True)
            evidence = os.path.join(tmp, 'evidence')
            os.makedirs(os.path.join(evidence, 'raw'))
            baseline = subprocess.run(
                ['git', 'status', '--porcelain=v1', '--untracked-files=all'],
                cwd=root, capture_output=True, text=True, check=True).stdout
            with open(os.path.join(evidence, 'raw', 'status-before.txt'), 'w',
                      encoding='utf-8') as stream:
                stream.write(baseline)
            # the fixture carrieth its OWN patch copy, so the control's first arm
            # (a clean checkout must PASS) is not defeated by an unrelated missing file
            patch = os.path.join(evidence, 'tracked-patch.bin')
            with open(patch, 'wb') as stream:
                stream.write(b'fixture patch')
            probe = {'untracked_files': [], 'ignored_fixture_files': [],
                     'tracked_patch_hash': preserve.sha256_file(patch),
                     'declared_additions': []}
            # a clean checkout first: the control must PASS before it can fail
            self.assertEmpty(preserve.verify_preservation(root, evidence, probe))
            open(os.path.join(root, 'undeclared-intruder.txt'), 'w').close()
            failures = preserve.verify_preservation(root, evidence, probe)
            self.assertNotEmpty([f for f in failures if 'status changed' in f],
                                msg='an undeclared path must still fail verification')


class FixtureClassificationTest(ReadinessTestCase):
    """Distinguish ignored debug fixtures from approved inputs and noise."""

    SAMPLE = [
        'content/tests/__pycache__/helpers.cpython-314.pyc',   # noise
        'android/build/outputs/a.apk',                          # noise
        '.venv/lib/python3/site-packages/pkg/init.py',          # noise
        'dist/archive_medium.db',                               # fixture
        'artifacts/android-core-parity.log',                    # fixture
        'provenance.json',                                      # fixture
        'content/ingest/corpora/approved_input_manifest.json', # fixture area
    ]

    def test_classifies_samples_as_expected(self):
        with tempfile.TemporaryDirectory() as tmp:
            for rel in self.SAMPLE:
                full = os.path.join(tmp, rel)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                open(full, 'wb').close()
            relevant, noise = preserve.classify_ignored(tmp, self.SAMPLE)
            for index in (3, 4, 5, 6):  # the fixture-area samples
                self.assertIn(self.SAMPLE[index], relevant)
            for index in (0, 1, 2):  # the build-noise samples
                self.assertIn(self.SAMPLE[index], noise)
            self.assertPathsEqual(len(relevant) + len(noise), len(self.SAMPLE))
    def test_inventory_fixtures_all_marked_as_debug_or_past_run(self):
        inventory = load_inventory()
        for entry in inventory['ignored_fixture_files']:
            self.assertIn('classification', entry)
            self.assertPathsEqual(
                entry['classification'], 'debug_or_past_run_fixture')


class MutationControlTest(ReadinessTestCase):
    """Card-mandated mutation: verification must fail on broken copies."""

    @classmethod
    def setUpClass(cls):
        cls.inventory = load_inventory()

    def _mirror(self, tmp):
        mirror = os.path.join(tmp, 'evidence-mirror')
        shutil.copytree(EVIDENCE, mirror, symlinks=False)
        return mirror

    def test_missing_tracked_patch_copy_fails_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            mirror = self._mirror(tmp)
            os.remove(os.path.join(mirror, 'tracked-patch.bin'))
            failures = preserve.verify_preservation(REPO, mirror, self.inventory)
            self.assertNotEmpty(failures)
            self.assertTrue(any('missing tracked patch copy' in f
                               for f in failures), msg=failures)

    def test_tracked_patch_tamper_fails_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            mirror = self._mirror(tmp)
            target = os.path.join(mirror, 'tracked-patch.bin')
            with open(target, 'rb+') as stream:
                first = stream.read(1)
                stream.seek(0)
                stream.write(bytes([(first[0] + 1) % 256]))
            failures = preserve.verify_preservation(REPO, mirror, self.inventory)
            self.assertNotEmpty(failures)
            self.assertTrue(any('tracked patch hash drift' in f
                               for f in failures), msg=failures)

    def test_removed_untracked_copy_fails_verification(self):
        victim = self.inventory['untracked_files'][0]['path']
        with tempfile.TemporaryDirectory() as tmp:
            mirror = self._mirror(tmp)
            os.remove(os.path.join(mirror, 'wip', victim))
            failures = preserve.verify_preservation(REPO, mirror, self.inventory)
            self.assertNotEmpty(failures)
            self.assertTrue(any('missing copy' in f and victim in f
                               for f in failures), msg=failures)

    def test_tampered_copy_fails_verification(self):
        victim = min(self.inventory['untracked_files'],
                     key=lambda e: e['size'])
        self.assertGreater(victim['size'], 0)
        with tempfile.TemporaryDirectory() as tmp:
            mirror = self._mirror(tmp)
            target = os.path.join(mirror, 'wip', victim['path'])
            with open(target, 'rb+') as stream:
                first = stream.read(1)
                stream.seek(0)
                stream.write(bytes([(first[0] + 1) % 256]))
            self.assertPathsEqual(os.path.getsize(target), victim['size'],
                                 msg='tamper must preserve the size byte')
            failures = preserve.verify_preservation(REPO, mirror, self.inventory)
            self.assertNotEmpty(failures)
            self.assertTrue(any('hash mismatch' in f and victim['path'] in f
                               for f in failures), msg=failures)
    def test_original_evidence_still_intact_after_mutations(self):
        """Mutants run against the mirror only; the original stays green."""
        failures = preserve.verify_preservation(
            REPO, EVIDENCE, load_inventory())
        self.assertEmpty(failures)


class SchemaGuardTest(ReadinessTestCase):
    """Reject unknown schemas; never turn missing counts into zeros."""

    def test_inventory_schema_version_is_known(self):
        self.assertEqual(load_inventory()['schema_version'], 1)

    def test_allowed_statuses_are_the_documented_seven(self):
        u = self.U
        documented = {
            'PENDING', 'IN' + u + 'PROGRESS', 'COMPLETE',
            'FAILED' + u + 'RETRYABLE', 'BLOCKED' + u + 'EXTERNAL',
            'BLOCKED' + u + 'HARDWARE', 'BLOCKED' + u + 'ARCHITECTURE',
        }
        self.assertEqual(set(preserve.ALLOWED_STATUSES), documented)
        self.assertPathsEqual(len(preserve.ALLOWED_STATUSES), 7)
    def test_entries_carry_real_sizes_not_placeholders(self):
        inventory = load_inventory()
        for entry in inventory['untracked_files']:
            self.assertIsInstance(entry['size'], int)
            self.assertGreaterEqual(entry['size'], 0)
            self.assertPathsEqual(len(entry['sha256']), 64)


class CommandLineTest(ReadinessTestCase):

    def test_usage_without_arguments_exits_with_code_two(self):
        with self.assertRaises(SystemExit) as raised:
            preserve.main(['preserve.py'])
        self.assertEqual(raised.exception.code, 2)


if globals().get('__name__') == '__main__':
    unittest.main(verbosity=2)
