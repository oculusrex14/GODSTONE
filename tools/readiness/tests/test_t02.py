#! /usr/bin/env python3
"""T02 regression suite: the deterministic runner and its evidence gates.

Scenarios (task card required cases):
 - state crash recovery: torn BUILD_STATE.json falls back to the previous
   checkpoint and the recovery is journaled
 - stale head rejection: a head that is not an ancestor of the worktree head
   is reported invalid
 - zero test rejection: a test command that exits 0 while collecting no tests
   is rejected, never counted as a pass
 - timeout classification: a command exceeding its timeout is classified
   TIMEOUT and is never passed through
 - unavailable mac executor: a non-local transport or missing executable
   blocks instead of pretending
 - tool call smoke test without repository mutation: a real subprocess runs
   through the runner and the worktree stays byte-clean

Mutations (task card):
 - runner must reject exit status 0 with zero tests
 - runner must reject a wrong SHA substituted in mac evidence
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
import run  # noqa: E402  module under test

REPO = os.environ.get('GODSTONE_BUILDER_ROOT',
                       os.path.dirname(os.path.dirname(TOOLS_DIR)))


def git(cwd, argv, check=True):
    proc = subprocess.run(['git', *argv], cwd=cwd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f'git {" ".join(argv)}: {proc.stderr[:200]}')
    return proc.stdout.strip()


def make_fixture_repo(base, head_status='clean'):
    """Build a throwaway git repo; evidence is kept outside the repo."""
    root = os.path.join(base, 'repo')
    evidence = os.path.join(base, 'evidence')
    os.makedirs(root, exist_ok=True)
    git(root, ['init', '-q', '-b', 'codex-fixture'])
    git(root, ['config', 'user.name', 'fixture'])
    git(root, ['config', 'user.email', 'fixture@example.invalid'])
    docs = os.path.join(root, 'docs', 'production-readiness')
    os.makedirs(docs, exist_ok=True)

    catalog = {
        'schema_version': 1,
        'tasks': [
            {'id': 'F01', 'phase': 'P0', 'title': 'fixture one',
             'dependencies': [], 'command_stages': {
                     'narrow': [{'cwd': '.',
                                 'argv': [sys.executable, '--version'],
                                 'requires': None, 'kind': 'command'}]}},
            {'id': 'F02', 'phase': 'P0', 'title': 'fixture two',
             'dependencies': ['F01'], 'command_stages': {
                     'narrow': [{'cwd': '.',
                                 'argv': [sys.executable, '-c',
                                          'import sys;'
                                          'sys.stderr.write("Ran 1 tests in 0.001s\\n");'
                                          'sys.stderr.write("OK\\n")'],
                                 'requires': 'python3',
                                 'kind': 'test',
                                 'assert_tests_positive': True}]}},
        ],
        'required_initial_order': ['F01', 'F02'],
    }
    state = {
        'schema_version': 1,
        'planning_baseline_sha': '0' * 40,
        'branch': 'codex-fixture',
        'last_observed_head': '0' * 40,
        'last_code_head': '0' * 40,
        'phase': 'P0', 'current_task': None, 'completed_tasks': {},
        'in_progress': None, 'next_task': 'F01',
    }
    executors = {
        'schema_version': 1,
        'executors': [
            {'id': 'mac-primary', 'os': 'Darwin',
             'authorized_transport': 'local',
             'workspace_root': root, 'capabilities': ['python']},
            {'id': 'dgx-linux', 'os': None, 'authorized_transport': None,
             'workspace_root': None, 'capabilities': []},
        ],
    }
    with open(os.path.join(docs, 'TASKS.json'), 'w', encoding='utf-8') as f:
        json.dump(catalog, f)
    with open(os.path.join(docs, 'BUILD_STATE.json'), 'w', encoding='utf-8') as f:
        json.dump(state, f)
    with open(os.path.join(docs, 'EXECUTORS.json'), 'w', encoding='utf-8') as f:
        json.dump(executors, f)
    git(root, ['add', '-A'])
    git(root, ['commit', '-q', '-m', 'fixture baseline'])
    head = git(root, ['rev-parse', 'HEAD'])
    state['last_observed_head'] = head
    state['last_code_head'] = head
    with open(os.path.join(docs, 'BUILD_STATE.json'), 'w', encoding='utf-8') as f:
        json.dump(state, f)
    git(root, ['add', '-A'])
    git(root, ['commit', '-q', '-m',
               'fixture state records observed head'])
    return run.Repo(root, evidence)


class ReadinessTestCase(unittest.TestCase):
    """Shared assertion vocabulary for the readiness suite."""

    def assertEmpty(self, seq, msg=None):
        self.assertEqual(list(seq), [], msg=msg)

    def assertNotEmpty(self, seq, msg=None):
        self.assertNotEqual(list(seq), [], msg=msg)

    def assertPathExists(self, path, msg=None):
        self.assertTrue(os.path.isfile(path), msg=msg or f'missing {path}')

    def assertPathsEqual(self, left, right, msg=None):
        self.assertEqual(str(left), str(right), msg=msg)


class StateCrashRecoveryTest(ReadinessTestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_torn_state_recovers_from_previous_checkpoint(self):
        run.write_state(self.repo, {'schema_version': 1,
                                    'checkpoint': 'v1'})
        run.write_state(self.repo, {'schema_version': 1,
                                    'checkpoint': 'v2'})
        live = self.repo.docs_file('BUILD_STATE.json')
        with open(live, 'w', encoding='utf-8') as stream:
            stream.write('{"schema_version": 1, "ch')  # torn write
        recovered = run.recover_state(self.repo)
        self.assertEqual(recovered.get('checkpoint'), 'v1')

    def test_recovery_without_any_checkpoint_is_fatal(self):
        live = self.repo.docs_file('BUILD_STATE.json')
        with open(live, 'w', encoding='utf-8') as stream:
            stream.write('')
        with self.assertRaises(run.StateInvalid):
            run.recover_state(self.repo)

    def test_duplicate_keys_are_rejected(self):
        path = self.repo.docs_file('DUP.json')
        with open(path, 'w', encoding='utf-8') as stream:
            stream.write('{"schema_version": 1, "k": 1, "k": 2}')
        with self.assertRaises(run.RunnerError):
            run.load_json_strict(path)

    def test_future_schema_version_is_rejected(self):
        path = self.repo.docs_file('FUTURE.json')
        with open(path, 'w', encoding='utf-8') as stream:
            stream.write('{"schema_version": 999}')
        with self.assertRaises(run.StateInvalid):
            run.load_json_strict(path)


class StaleHeadTest(ReadinessTestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _read_state(self):
        return json.load(open(self.repo.docs_file('BUILD_STATE.json'),
                              encoding='utf-8'))

    def _write_state(self, state):
        with open(self.repo.docs_file('BUILD_STATE.json'), 'w',
                 encoding='utf-8') as stream:
            stream.write(json.dumps(state, sort_keys=True))

    def test_current_head_validates(self):
        problems = run.validate_state(self.repo)
        self.assertEmpty(problems)

    def test_stale_head_is_rejected(self):
        state = self._read_state()
        state['last_observed_head'] = 'f' * 40  # not an ancestor, foreign sha
        self._write_state(state)
        problems = run.validate_state(self.repo)
        self.assertTrue(any('not an ancestor' in p or 'stale' in p
                           for p in problems), msg=problems)


class CommandClassificationTest(ReadinessTestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_zero_tests_exit_zero_is_rejected(self):
        spec = {'argv': [sys.executable, '-c', 'pass'], 'cwd': '.',
                'kind': 'test'}
        result = run.run_command(self.repo, spec, 'F01', 'narrow', None)
        self.assertEqual(result.outcome, 'REJECTED')
        self.assertEqual(result.exit_code, 0)
        self.assertPathExists(os.path.join(self.repo.evidence, 'F01', 'logs',
                                          os.path.basename(result.log_path)))

    def test_real_test_run_counts_and_classification(self):
        script = ('import sys;'
                  'sys.stderr.write("Ran 2 tests in 0.001s\\n");'
                  'sys.stderr.write("FAILED (failures=1, errors=0, '
                  'skipped=0)\\n");'
                  'raise SystemExit(1)')
        spec = {'argv': [sys.executable, '-c', script], 'cwd': '.',
                'kind': 'test'}
        result = run.run_command(self.repo, spec, 'F02', 'narrow', None)
        self.assertEqual(result.outcome, 'FAILED')
        self.assertEqual(result.tests_executed, 2)
        self.assertEqual(result.tests_failed, 1)

    def test_passing_test_counts_positive(self):
        script = ('import sys;'
                  'sys.stderr.write("Ran 3 tests in 0.001s\\n");'
                  'sys.stderr.write("OK\\n")')
        spec = {'argv': [sys.executable, '-c', script], 'cwd': '.',
                'kind': 'test', 'assert_tests_positive': True}
        result = run.run_command(self.repo, spec, 'F02', 'narrow', None)
        self.assertEqual(result.outcome, 'PASSED')
        self.assertEqual(result.tests_executed, 3)
        self.assertEqual(result.tests_passed, 3)

    def test_timeout_is_classified_not_passed_through(self):
        spec = {'argv': ['/bin/sleep', '10'], 'cwd': '.', 'kind': 'command',
                'timeout': 1}
        result = run.run_command(self.repo, spec, 'F01', 'narrow', None)
        self.assertEqual(result.outcome, 'TIMEOUT')
        self.assertIsNone(result.exit_code)
        self.assertNotEmpty(result.note)

    def test_shell_string_argv_is_refused(self):
        with self.assertRaises(run.CommandError):
            run.run_command(self.repo, {'argv': 'ls -la', 'cwd': '.'},
                           'F01', 'narrow', None)

    def test_missing_required_field_manifest_is_refused(self):
        with self.assertRaises(run.CommandError):
            run.run_command(self.repo, {'cwd': '.'}, 'F01', 'narrow', None)

    def test_cwd_escaping_the_repository_is_refused(self):
        with self.assertRaises(run.CommandError):
            run.run_command(self.repo, {'argv': ['/bin/true'],
                                       'cwd': '../../etc'},
                           'F01', 'narrow', None)


class ExecutorAvailabilityTest(ReadinessTestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_missing_executable_blocks_with_reason(self):
        spec = {'argv': ['no-such-tool-on-this-machine', '--version'],
                'cwd': '.', 'requires': 'no-such-tool-on-this-machine'}
        local = run.Executor({'id': 'mac-primary',
                              'authorized_transport': 'local',
                              'workspace_root': self.repo.root})
        with self.assertRaises(run.BlockedExternal) as ctx:
            run.run_command(self.repo, spec, 'F01', 'narrow', local)
        self.assertIn('not found', str(ctx.exception))

    def test_non_local_transport_executor_is_blocked(self):
        remote = run.Executor({'id': 'dgx-linux',
                               'authorized_transport': 'ssh',
                               'workspace_root': '/remote'})
        self.assertFalse(remote.runnable())
        with self.assertRaises(run.BlockedExternal) as ctx:
            run.run_command(self.repo, {'argv': ['/bin/true'], 'cwd': '.',
                                       'kind': 'command'},
                           'F01', 'narrow', remote)
        self.assertIn('transport', str(ctx.exception))


class ToolSmokeTest(ReadinessTestCase):
    """Tool call smoke test: a real subprocess, no repo mutation."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_tool_call_smoke_without_repo_mutation(self):
        before = git(self.repo.root, ['status', '--porcelain=v1',
                                     '--untracked-files=all'])
        local = run.Executor({'id': 'mac-primary',
                              'authorized_transport': 'local',
                              'workspace_root': self.repo.root})
        result = run.run_command(
            self.repo, {'argv': [sys.executable, '--version'], 'cwd': '.',
                        'kind': 'command'}, 'F01', 'narrow', local)
        after = git(self.repo.root, ['status', '--porcelain=v1',
                                    '--untracked-files=all'])
        self.assertEqual(result.outcome, 'PASSED')
        self.assertEqual(result.exit_code, 0)
        self.assertPathsEqual(before, after)
        log = os.path.join(self.repo.evidence, result.log_path)
        self.assertPathExists(log)
        self.assertPathsEqual(run.preserve.sha256_file(log),
                             result.log_sha256)

    def test_command_entry_is_installed_in_commands_log(self):
        local = run.Executor({'id': 'mac-primary',
                              'authorized_transport': 'local',
                              'workspace_root': self.repo.root})
        run.run_command(self.repo, {'argv': [sys.executable, '--version'],
                                   'cwd': '.', 'kind': 'command'},
                       'F01', 'narrow', local)
        doc = json.load(open(os.path.join(self.repo.evidence, 'F01',
                                         'commands.json'),
                             encoding='utf-8'))
        entry = doc['commands'][-1]
        self.assertEqual(entry['task'], 'F01')
        self.assertEqual(entry['stage'], 'narrow')
        self.assertEqual(entry['argv'], [sys.executable, '--version'])
        self.assertEqual(entry['outcome'], 'PASSED')


class WrongEvidenceMutationTest(ReadinessTestCase):
    """Mutations demanded by the task card: wrong SHAs must be rejected."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _complete(self, commit, tree):
        state = json.load(open(self.repo.docs_file('BUILD_STATE.json'),
                                encoding='utf-8'))
        state['completed_tasks'] = {'F01': {
            'status': 'COMPLETE', 'implementation_commit': commit,
            'tested_tree_sha': tree, 'commands': []}}
        with open(self.repo.docs_file('BUILD_STATE.json'), 'w',
                 encoding='utf-8') as stream:
            stream.write(json.dumps(state, sort_keys=True))

    def test_wrong_commit_object_rejected(self):
        self._complete('e' * 40, '0' * 40)
        problems = run.validate_state(self.repo)
        self.assertTrue(any('not a known commit object' in p
                           for p in problems), msg=problems)

    def test_wrong_substituted_tree_rejected(self):
        real_commit = git(self.repo.root, ['rev-parse', 'HEAD'])
        self._complete(real_commit, 'a' * 40)  # substituted wrong tree
        problems = run.validate_state(self.repo)
        self.assertTrue(any('does not match the tree' in p
                           for p in problems), msg=problems)

    def test_complete_with_missing_dependency_rejected(self):
        real_commit = git(self.repo.root, ['rev-parse', 'HEAD'])
        real_tree = git(self.repo.root, ['rev-parse', 'HEAD^{tree}'])
        state = json.load(open(self.repo.docs_file('BUILD_STATE.json'),
                                encoding='utf-8'))
        state['completed_tasks'] = {'F02': {
            'status': 'COMPLETE', 'implementation_commit': real_commit,
            'tested_tree_sha': real_tree, 'commands': []}}
        with open(self.repo.docs_file('BUILD_STATE.json'), 'w',
                 encoding='utf-8') as stream:
            stream.write(json.dumps(state, sort_keys=True))
        problems = run.validate_state(self.repo)
        self.assertTrue(any('F02' in p and 'F01' in p for p in problems),
                        msg=problems)

    def test_skipped_status_is_not_among_allowed(self):
        self.assertNotIn('SKIPPED_COMPLETE', run.ALLOWED_STATUSES)
        for status in ('PENDING', 'IN_PROGRESS', 'COMPLETE', 'FAILED_RETRYABLE',
                       'BLOCKED_EXTERNAL', 'BLOCKED_HARDWARE',
                       'BLOCKED_ARCHITECTURE'):
            self.assertIn(status, run.ALLOWED_STATUSES)


class SchedulerTest(ReadinessTestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_next_task_is_initial_first(self):
        self.assertEqual(run.next_task(self.repo), 'F01')

    def test_next_task_follows_dependency_completion(self):
        real_commit = git(self.repo.root, ['rev-parse', 'HEAD'])
        real_tree = git(self.repo.root, ['rev-parse', 'HEAD^{tree}'])
        state = json.load(open(self.repo.docs_file('BUILD_STATE.json'),
                              encoding='utf-8'))
        state['completed_tasks'] = {'F01': {
            'status': 'COMPLETE', 'implementation_commit': real_commit,
            'tested_tree_sha': real_tree, 'commands': []}}
        with open(self.repo.docs_file('BUILD_STATE.json'), 'w',
                 encoding='utf-8') as stream:
            stream.write(json.dumps(state, sort_keys=True))
        self.assertEqual(run.next_task(self.repo), 'F02')

    def test_blocked_dependency_never_maps_to_ready(self):
        state = json.load(open(self.repo.docs_file('BUILD_STATE.json'),
                              encoding='utf-8'))
        state['completed_tasks'] = {'F01': {'status': 'BLOCKED_EXTERNAL',
                                            'commands': []}}
        with open(self.repo.docs_file('BUILD_STATE.json'), 'w',
                 encoding='utf-8') as stream:
            stream.write(json.dumps(state, sort_keys=True))
        self.assertIsNone(run.next_task(self.repo))


class SelftestCliTest(ReadinessTestCase):
    """The built-in suite itself, driven through the command line."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = make_fixture_repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _main(self, argv):
        return run.main(['--repo', self.repo.root, '--evidence',
                        self.repo.evidence, *argv])

    def test_selftest_reports_positive_counts_ok(self):
        self.assertEqual(self._main(['selftest']), 0)

    def test_next_prints_a_ready_task(self):
        self.assertEqual(self._main(['next']), 0)

    def test_validate_state_ok_on_clean_fixture(self):
        self.assertEqual(self._main(['validate-state']), 0)

    def test_task_stage_narrow_runs_and_reports(self):
        self.assertEqual(self._main(['task', 'F01', '--stage', 'narrow']), 0)

    def test_unknown_task_exits_with_usage(self):
        self.assertEqual(self._main(['task', 'NOPE', '--stage', 'narrow']),
                        run.EXIT_USAGE)

    def test_ladder_requires_profile(self):
        with self.assertRaises(SystemExit) as ctx:
            self._main(['ladder', 'L0'])
        self.assertEqual(ctx.exception.code, 2)


if globals().get('__name__') == '__main__':
    unittest.main(verbosity=2)
