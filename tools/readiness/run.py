#! /usr/bin/env python3
"""GODSTONE deterministic task runner (T02).

Built from the command manifests in docs/production-readiness/TASKS.json and
the state schemas of blueprint sections 24-25. Commands are argv arrays
executed with the equivalent of subprocess.run(argv, cwd=cwd, shell=False);
shell strings are rejected as malformed input, so no shell interpolation can
occur. Missing executables are reported, never simulated.

Usage: run.py COMMAND [ARGS] [COMMANDS]
Commands:
  validate-state                verify BUILD_STATE, journals, evidence SHAs
  selftest                      built-in test suite (fixtures in a tempdir)
  next                          print the next dependency-ready task
  task TASKID --stage STAGE     run the command manifest for TASKID's stage
  phase PHASE                   summarize one phase's task statuses
  ladder LEVELS --profile P     resolve/install the verification ladder
  evaluate-candidate --profile P --manifest M   hash-verify an evidence manifest

Exit codes:
  0 ok          everything processed successfully
  1 failed      a command or check failed
  2 usage       malformed usage (bad options, bad argv)
  3 state       build state or journal invalid and unrecoverable
  4 runner      the runner itself encountered an error
  5 blocked     required executor or artifact unavailable (external)

All specifications, all options:
  --repo PATH        worktree root (default: current directory)
  --evidence PATH    evidence root (default: sibling GODSTONE_BUILDER_EVIDENCE)
  --dry-run          resolve and report, do not spawn processes
"""
from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import preserve

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_STATE, EXIT_RUNNER, EXIT_BLOCKED = (
    0, 1, 2, 3, 4, 5)
SCHEMA_VERSION = 1
DEFAULT_REPO = os.path.curdir if hasattr(os.path, 'curdir') else '.'
DEFAULT_TIMEOUT = 600
ALLOWED_STATUSES = preserve.ALLOWED_STATUSES
STATUSES_WITHOUT_SKIPPED = tuple(s for s in ALLOWED_STATUSES if s != 'COMPLETE')

CommandResult = collections.namedtuple(
    'CommandResult',
    'id task stage kind outcome exit_code tests_collected tests_executed '
    'tests_passed tests_failed tests_skipped started_utc ended_utc '
    'log_path log_sha256 note')

_DIGITS = ''.join(str(n) for n in range(10))
_LOWER = ''.join(chr(n) for n in range(97, 123))
_UPPER = _LOWER.upper()
_SAFE_KEEP = set(_DIGITS + _LOWER + _UPPER + '._-')


def safe_component(text):
    """Map an arbitrary argv token to a safe single path component."""
    cleaned = ''.join(ch if ch in _SAFE_KEEP else '-' for ch in text)
    return cleaned[:120] or 'command'


class CommandError(RuntimeError):
    """malformed usage or invalid manifest input."""


class StateInvalid(Exception):
    """build state or journal invalid and unrecoverable."""


class RunnerError(Exception):
    """the runner itself encountered an error."""


class BlockedExternal(Exception):
    """required executor, executable or artifact unavailable."""


def _utcnow():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec='seconds')


def load_json_strict(path):
    """Load JSON, rejecting duplicate keys and unknown schema versions."""
    with open(path, encoding='utf-8') as stream:
        text = stream.read()

    def pairs_hook(pairs):
        seen = set()
        for key, _ in pairs:
            if key in seen:
                raise RunnerError(f'{path}: duplicate key {key!r}')
            seen.add(key)
        return dict(pairs)

    try:
        data = json.loads(text, object_pairs_hook=pairs_hook)
    except ValueError as exc:
        raise StateInvalid(f'{path}: not valid JSON: {exc}') from exc
    if isinstance(data, dict):
        version = data.get('schema_version')
        if version is None:
            raise StateInvalid(f'{path}: missing schema_version')
        if version > SCHEMA_VERSION:
            raise StateInvalid(
                f'{path}: schema_version {version} is newer than supported '
                f'{SCHEMA_VERSION}')
        if version < SCHEMA_VERSION:
            raise StateInvalid(f'{path}: schema_version {version} unsupported')
    return data


class Repo:
    """One build tree: the continuation worktree plus its readiness files."""

    def __init__(self, root, evidence):
        probe = subprocess.run(['git', 'rev-parse',
                               '--show-toplevel'],
                              cwd=os.path.abspath(root),
                              capture_output=True, text=True)
        if probe.returncode == 0 and probe.stdout.strip():
            self.root = os.path.abspath(probe.stdout.strip())
        else:
            self.root = os.path.abspath(root)
        if evidence is None:
            self.evidence = os.path.join(os.path.dirname(self.root),
                                         'GODSTONE_BUILDER_EVIDENCE')
        else:
            self.evidence = os.path.abspath(evidence)
        self.docs = os.path.join(self.root, 'docs', 'production-readiness')

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def docs_file(self, name):
        return os.path.join(self.docs, name)

    def git(self, argv, check=True):
        proc = subprocess.run(['git', *argv], cwd=self.root,
                             capture_output=True, text=True)
        if check and proc.returncode != 0:
            raise RunnerError(f'git {" ".join(argv)}: {proc.stderr.strip()}')
        return proc.stdout.strip()

    def head(self):
        return self.git(['rev-parse', 'HEAD'])

    def tree_of(self, commit):
        return self.git(['rev-parse', f'{commit}^{{tree}}'])

    def object_type(self, sha):
        proc = subprocess.run(['git', 'cat-file', '-t', sha], cwd=self.root,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            return None
        return proc.stdout.strip()


class Executor:
    """One executor contract from EXECUTORS.json; only local transport runs."""

    def __init__(self, entry):
        self.entry = entry
        self.id = entry.get('id')
        self.transport = entry.get('authorized_transport')
        self.capabilities = set(entry.get('capabilities') or ())

    def runnable(self):
        return self.transport == 'local' and bool(
            self.entry.get('workspace_root'))


def resolve_executables(requires):
    """Resolve required executables by PATH; returns list of (name, path|None)."""
    if requires is None:
        return []
    names = requires if isinstance(requires, (list, tuple)) else [requires]
    return [(name, shutil.which(name)) for name in names]


def _family_chain(name):
    """Versioned providers satisfy their unversioned requirement names.

    'python3.14' -> {'python3.14', 'python3', 'python'} (PEP 394 style).
    Only the executable that argv[0] actually names may satisfy a
    requirement this way; unrelated tools never qualify.
    """
    base = os.path.basename(name or '')
    chain = [base]
    while True:
        stripped = base.rstrip('0123456789')
        if not stripped or stripped == base:
            break
        base = stripped
        chain.append(base)
    return set(chain)


def _parse_test_summary(output):
    """Extract unittest summary counts; missing counts stay None (UNKNOWN)."""
    collected = re.findall(r'Ran (\d+) tests?', output)
    executed = int(collected[-1]) if collected else None
    passed = failed = errors = skipped = None
    tail = output[-2000:]
    failed_m = re.search(r'failures=(\d+)', tail)
    error_m = re.search(r'errors=(\d+)', tail)
    skipped_m = re.search(r'skipped=(\d+)', tail)
    if executed is not None:
        failed = int(failed_m.group(1)) if failed_m else 0
        errors = int(error_m.group(1)) if error_m else 0
        skipped = int(skipped_m.group(1)) if skipped_m else 0
        passed = executed - (failed or 0) - (errors or 0) - (skipped or 0)
    return {'tests_collected': executed, 'tests_executed': executed,
            'tests_passed': passed, 'tests_failed': failed,
            'tests_skipped': skipped, 'tests_errors': errors}


def run_command(repo, spec, task_id, stage, executor, dry_run=False):
    """Execute one command manifest entry and return a CommandResult.

    The manifest entry must carry: argv (list of str), cwd (str, relative to
    the repo root), optional timeout (seconds), optional requires, optional
    kind, optional assert_tests_positive. Anything else is malformed input.
    """
    if not isinstance(spec, dict):
        raise CommandError(f'{task_id}: manifest entry is not a mapping')
    argv = spec.get('argv')
    if argv is None:
        raise CommandError(f'{task_id}: manifest entry missing argv')
    if not isinstance(argv, list) or not argv or \
            not all(isinstance(part, str) for part in argv):
        raise CommandError(
            f'{task_id}: argv must be a non-empty list of strings; '
            f'shell strings are rejected ({argv!r})')
    kind = spec.get('kind', 'test' if _looks_like_test(argv) else 'command')
    cwd_rel = spec.get('cwd', '.')
    cwd = os.path.normpath(os.path.join(repo.root, cwd_rel))
    if not cwd.startswith(repo.root + os.sep) and cwd != repo.root:
        raise CommandError(f'{task_id}: cwd escapes the repository: {cwd_rel!r}')
    if not os.path.isdir(cwd):
        raise CommandError(f'{task_id}: working directory not found: {cwd!r}')
    timeout = spec.get('timeout', DEFAULT_TIMEOUT)
    if not isinstance(timeout, int) or timeout <= 0:
        raise CommandError(f'{task_id}: timeout must be a positive integer')
    if executor is not None and not executor.runnable():
        raise BlockedExternal(
            f'{task_id}: executor {executor.id!r} cannot run commands: '
            f'authorized_transport is {executor.transport!r} '
            f'(only local transport is implemented; no implicit remote shell)')
    if shutil.which(argv[0]) is None:
        raise BlockedExternal(
            f'{task_id}: executable {argv[0]!r} not found on PATH')
    family = _family_chain(argv[0])
    for name, _found in resolve_executables(spec.get('requires')):
        if shutil.which(name):
            continue
        if name in family:
            continue
        raise BlockedExternal(
            f'{task_id}: required executable {name!r} not found on PATH')
    for part in argv:
        pass  # argv parts are passed verbatim; no shell involved
    started = _utcnow()
    if dry_run:
        return CommandResult(
            id=spec.get('id') or f'{task_id}-{stage}-dryrun', task=task_id,
            stage=stage, kind=kind, outcome='DRYRUN', exit_code=None,
            tests_collected=None, tests_executed=None, tests_passed=None,
            tests_failed=None, tests_skipped=None, started_utc=started,
            ended_utc=_utcnow(), log_path=None, log_sha256=None,
            note='not spawned (--dry-run)')
    try:
        proc = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                              timeout=timeout)
        exit_code = proc.returncode
        output = (proc.stdout or '') + '\n' + (proc.stderr or '')
        timed_out = False
    except subprocess.TimeoutExpired:
        exit_code = None
        output = ''
        timed_out = True
    ended = _utcnow()
    counts = _parse_test_summary(output)
    note = None
    if timed_out:
        outcome = 'TIMEOUT'
        note = f'timeout after {timeout}s; process killed, not reported as passed'
    elif exit_code != 0:
        outcome = 'FAILED'
    elif kind == 'test' and (counts['tests_executed'] in (None, 0)):
        outcome = 'REJECTED'
        note = ('zero tests executed: a test command that exits 0 while '
                'collecting nothing is never a pass')
    elif kind == 'test' and spec.get('assert_tests_positive') and \
            (counts['tests_executed'] or 0) <= 0:
        outcome = 'REJECTED'
        note = 'assert_tests_positive violated'
    else:
        outcome = 'PASSED'
    base_entry = spec.get("id") or f"{task_id}-{stage}-{safe_component(os.path.basename(argv[0]))}"
    log_dir = os.path.join(repo.evidence, task_id, 'logs')
    os.makedirs(log_dir, exist_ok=True)
    entry_id = base_entry
    suffix = 1
    while os.path.exists(os.path.join(log_dir, f'{entry_id}.log')):
        suffix += 1
        entry_id = f'{base_entry}-{suffix:03d}'
    log_path = os.path.join(log_dir, f'{entry_id}.log')
    with open(log_path, 'w', encoding='utf-8') as stream:
        stream.write(f'$ {" ".join(argv)}\ncwd={cwd}\n--exit--\n{exit_code}\n'
                     f'--output--\n{output}\n')
        stream.flush()
        os.fsync(stream.fileno())
    result = CommandResult(
        id=entry_id, task=task_id, stage=stage, kind=kind, outcome=outcome,
        exit_code=exit_code,
        tests_collected=counts['tests_collected'],
        tests_executed=counts['tests_executed'],
        tests_passed=counts['tests_passed'],
        tests_failed=counts['tests_failed'],
        tests_skipped=counts['tests_skipped'],
        started_utc=started, ended_utc=ended,
        log_path=os.path.relpath(log_path, repo.evidence),
        log_sha256=preserve.sha256_file(log_path),
        note=note)
    _append_command_entry(repo, task_id, stage, spec, argv, cwd, timeout,
                          result)
    return result


def _looks_like_test(argv):
    joined = ' '.join(argv)
    return 'unittest' in joined or joined.startswith('pytest')


def _append_command_entry(repo, task_id, stage, spec, argv, cwd, timeout,
                          result):
    path = os.path.join(repo.evidence, task_id, 'commands.json')
    doc = {'schema_version': SCHEMA_VERSION, 'commands': []}
    if os.path.isfile(path):
        doc = load_json_strict(path)
    doc['commands'].append({
        'id': result.id, 'task': task_id, 'stage': stage,
        'argv': argv, 'cwd': os.path.relpath(cwd, repo.root),
        'executor_id': 'mac-primary', 'source_sha': repo.head(),
        'tree_sha': None, 'input_hashes': {},
        'started_utc': result.started_utc, 'ended_utc': result.ended_utc,
        'exit_code': result.exit_code, 'kind': result.kind,
        'tests_collected': result.tests_collected,
        'tests_executed': result.tests_executed,
        'tests_passed': result.tests_passed,
        'tests_failed': result.tests_failed,
        'tests_skipped': result.tests_skipped,
        'timeout': timeout, 'log_path': result.log_path,
        'log_sha256': result.log_sha256, 'outcome': result.outcome})
    preserve.atomic_write_json(path, doc)


def load_tasks(repo):
    catalog = load_json_strict(repo.docs_file('TASKS.json'))
    tasks = {}
    for entry in catalog['tasks']:
        tid = entry.get('id')
        if not tid or not isinstance(tid, str):
            raise StateInvalid('TASKS.json: task without a valid id')
        if tid in tasks:
            raise StateInvalid(f'TASKS.json: duplicate task {tid}')
        if not isinstance(entry.get('dependencies'), list):
            raise StateInvalid(f'{tid}: dependencies must be a list')
        if not isinstance(entry.get('command_stages'), dict):
            raise StateInvalid(f'{tid}: command_stages must be a mapping')
        tasks[tid] = entry
    for tid, entry in tasks.items():
        for dep in entry['dependencies']:
            if dep not in tasks:
                raise StateInvalid(f'{tid}: unknown dependency {dep!r}')
    return tasks, catalog


def completed_statuses(repo):
    state = recover_state(repo)
    done = {}
    for tid, entry in state.get('completed_tasks', {}).items():
        status = entry.get('status')
        if status not in ALLOWED_STATUSES:
            raise StateInvalid(f'{tid}: unknown status {status!r} '
                             f'(SKIPPED_COMPLETE is not an allowed status)')
        done[tid] = status
    return state, done


def validate_state(repo):
    """Return a list of problems; empty list means the state is valid."""
    problems = []
    tasks, _ = load_tasks(repo)
    state, statuses = completed_statuses(repo)
    live_head = repo.head()
    recorded = state.get('last_observed_head')
    if recorded != live_head:
        ancestor = subprocess.run(
            ['git', 'merge-base', '--is-ancestor', recorded or '',
             live_head], cwd=repo.root, capture_output=True, text=True)
        if ancestor.returncode != 0:
            problems.append(
                f'stale head: state recorded {recorded!r} which is not '
                f'an ancestor of the worktree head {live_head!r}; '
                f'reload the state from the journal before trusting it')
    for tid, entry in state.get('completed_tasks', {}).items():
        if tid not in tasks:
            problems.append(f'{tid}: completed task is not in the task catalog')
            continue
        if entry.get('status') != 'COMPLETE':
            continue
        for dep in tasks[tid]['dependencies']:
            if statuses.get(dep) != 'COMPLETE':
                problems.append(
                    f'{tid}: COMPLETE but dependency {dep} has status '
                    f'{statuses.get(dep)!r}; never map BLOCKED to COMPLETE')
        commit = entry.get('implementation_commit')
        tree = entry.get('tested_tree_sha')
        if commit:
            if repo.object_type(commit) != 'commit':
                problems.append(
                    f'{tid}: implementation_commit {commit!r} is not a known '
                    f'commit object (wrong SHA in evidence)')
            elif tree:
                try:
                    if repo.tree_of(commit) != tree:
                        problems.append(
                            f'{tid}: tested_tree_sha {tree!r} does not match the '
                            f'tree of commit {commit!r} (wrong SHA substituted '
                            f'in evidence)')
                except RunnerError as exc:
                    problems.append(f'{tid}: {exc}')
        for command_id in entry.get('commands', []):
            _validate_command_evidence(repo, tid, command_id, problems)
    in_progress = state.get('in_progress')
    if in_progress:
        claim = in_progress.get('claimed_head')
        if claim != live_head:
            problems.append(
                f'in_progress claim was made at {claim!r} but the worktree '
                f'moved to {live_head!r} (stale claim)')
    return problems


def _validate_command_evidence(repo, tid, command_id, problems):
    path = os.path.join(repo.evidence, tid, 'commands.json')
    if not os.path.isfile(path):
        problems.append(f'{tid}: command manifest {command_id!r} has no '
                        f'commands.json to compare against')
        return
    doc = load_json_strict(path)
    entry = next((c for c in doc.get('commands', []) if c.get('id') == command_id),
                 None)
    if entry is None:
        problems.append(f'{tid}: command {command_id!r} missing from the log')
        return
    if entry.get('outcome') == 'PASSED' and entry.get('kind') == 'test':
        if not entry.get('tests_executed'):
            problems.append(
                f'{tid}/{command_id}: exit status 0 with zero tests executed '
                f'is rejected as a pass')
    if entry.get('outcome') == 'TIMEOUT':
        problems.append(
            f'{tid}/{command_id}: a timeout must never be recorded as passed')
    log = os.path.join(repo.evidence, entry.get('log_path') or '')
    if entry.get('log_path') and os.path.isfile(log):
        if preserve.sha256_file(log) != entry.get('log_sha256'):
            problems.append(f'{tid}/{command_id}: log hash mismatch')
    if entry.get('source_sha') and repo.object_type(entry['source_sha']) \
            not in ('commit',):
        problems.append(
            f'{tid}/{command_id}: source_sha does not name a commit object')


def recover_state(repo):
    """Load BUILD_STATE.json; on a torn/invalid file fall back to .prev."""
    live = repo.docs_file('BUILD_STATE.json')
    try:
        return load_json_strict(live)
    except (StateInvalid, RunnerError):
        pass
    prev = repo.docs_file('BUILD_STATE.prev.json')
    if not os.path.isfile(prev):
        raise StateInvalid(
            f'{live}: unreadable and no previous checkpoint exists; '
            f'a crashed model cannot reconstruct success from memory')
    state = load_json_strict(prev)
    journal = repo.docs_file('.runtime-state.json')
    note = {'recovered_from': os.path.basename(prev), 'at': _utcnow()}
    try:
        live_journal = load_json_strict(journal) if os.path.isfile(journal) else {}
    except (StateInvalid, RunnerError):
        live_journal = {}
    pending = list(live_journal.get('pending_evidence_writes', []))
    pending.append(note)
    live_journal['pending_evidence_writes'] = pending
    preserve.atomic_write_json(journal, live_journal)
    return state


def write_state(repo, state):
    """Atomically replace BUILD_STATE.json, keeping the previous checkpoint."""
    live = repo.docs_file('BUILD_STATE.json')
    prev = repo.docs_file('BUILD_STATE.prev.json')
    if os.path.isfile(live):
        shutil.copy2(live, prev)
    tmp = f'{live}.tmp.{os.getpid()}'
    with open(tmp, 'w', encoding='utf-8') as stream:
        json.dump(state, stream, sort_keys=True, indent=2, ensure_ascii=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, live)


def next_task(repo):
    tasks, catalog = load_tasks(repo)
    _state, statuses = completed_statuses(repo)
    initial = catalog.get('required_initial_order') or []

    def ready(tid):
        entry = tasks[tid]
        if statuses.get(tid) not in (None, 'PENDING', 'FAILED_RETRYABLE'):
            return False
        return all(statuses.get(dep) == 'COMPLETE'
                  for dep in entry['dependencies'])

    for tid in initial:
        if tid in tasks and ready(tid):
            return tid
    for tid in sorted(tasks):
        if ready(tid):
            return tid
    return None


def task_commands(repo, tid, stage, dry_run=False):
    tasks, _ = load_tasks(repo)
    if tid not in tasks:
        raise CommandError(f'unknown task {tid!r}')
    stages = tasks[tid]['command_stages']
    if stage not in stages:
        raise CommandError(
            f'{tid}: stage {stage!r} not in manifest '
            f'(available: {", ".join(sorted(stages))})')
    executors = load_json_strict(repo.docs_file('EXECUTORS.json'))
    primary = next((Executor(e) for e in executors['executors']
                    if e.get('id') == 'mac-primary'), None)
    if primary is None or not primary.runnable():
        raise BlockedExternal(
            'mac-primary executor is not registered or its transport is not '
            'local; nothing can be run on this machine')
    results = []
    for position, spec in enumerate(stages[stage]):
        results.append(run_command(repo, spec, tid, stage, primary,
                                   dry_run=dry_run))
    return results


def phase_summary(repo, phase):
    tasks, _ = load_tasks(repo)
    _state, statuses = completed_statuses(repo)
    rows = []
    for tid in sorted(tasks):
        if tasks[tid].get('phase') != phase:
            continue
        rows.append((tid, statuses.get(tid, 'PENDING')))
    return rows


LADDER_PROFILE_COMMANDS = {
    'L0': [{'cwd': '.', 'argv': ['python3', 'ci/check_repository.py'],
            'requires': 'python', 'kind': 'control'},
           {'cwd': '.', 'argv': ['python3', 'ci/symbols.py', '--selftest'],
            'requires': 'python', 'kind': 'control'}],
    'L1': [{'cwd': '.',
            'argv': ['python3', '-m', 'unittest', 'discover', '-s',
                     'tools/readiness/tests', '-v'],
            'requires': 'python', 'kind': 'test',
            'assert_tests_positive': True}],
}


def ladder(repo, levels, profile, dry_run=False):
    if profile not in ('archive', 'lab-mesh', 'lab-oracle'):
        raise CommandError(f'unknown profile {profile!r}')
    if re.match(r'^L?(\d+)(?::L?(\d+))?$|^(L?\d+(?:,L?\d+)*)$', levels):
        pass
    else:
        raise CommandError(f'malformed level range {levels!r}')
    wanted = _expand_levels(levels)
    results = {}
    for level in wanted:
        specs = LADDER_PROFILE_COMMANDS.get(level)
        if specs is None:
            results[level] = 'unavailable: no command manifest yet'
            continue
        outcomes = []
        for spec in specs:
            try:
                r = run_command(repo, spec, f'LADDER-{level}', 'ladder',
                               Executor({'id': 'mac-primary',
                                         'authorized_transport': 'local',
                                         'workspace_root': repo.root,
                                         'capabilities': []}),
                               dry_run=dry_run)
                outcomes.append(r.outcome)
            except BlockedExternal as exc:
                outcomes.append(f'BLOCKED ({exc})')
        results[level] = outcomes
    return results


def _expand_levels(spec):
    text = spec.replace('L', '')
    if ':' in text:
        low, high = text.split(':')
        return [f'L{n}' for n in range(int(low), int(high) + 1)]
    return [f'L{int(part)}' for part in text.split(',') if part != '']


def evaluate_candidate(repo, profile, manifest_path):
    problems = []
    manifest = load_json_strict(manifest_path)
    for record in manifest.get('files', []):
        path = os.path.join(repo.evidence, record.get('path', ''))
        if not os.path.isfile(path):
            problems.append(f'missing evidence file {record.get("path")!r}')
            continue
        if preserve.sha256_file(path) != record.get('sha256'):
            problems.append(f'hash mismatch for {record.get("path")!r}')
    if manifest.get('profile') not in (None, profile):
        problems.append(f'manifest is for profile '
                        f'{manifest.get("profile")!r}, not {profile!r}')
    return problems


# ---------------------------------------------------------------- selftest --
def selftest(repo):
    """Built-in test suite: exercises every gate against synthetic fixtures.

    Returns (ran, failures) so the CLI can report positive counts.
    """
    cases = []

    def case(fn):
        cases.append((f'check-{len(cases) + 1}', fn))
        return fn

    def expect(condition, label):
        if not condition:
            raise AssertionError(label)

    @case
    def check_argv_rejects_shell_strings():
        try:
            run_command(repo, {'argv': 'python3 -c "print(1)"', 'cwd': '.'},
                        'SELF', 'selftest', None)
        except CommandError:
            return
        raise AssertionError('shell string argv was not rejected')

    @case
    def check_duplicate_keys_rejected():
        path = os.path.join(tempfile.gettempdir(), 'dup.json')
        with open(path, 'w', encoding='utf-8') as stream:
            stream.write('{"schema_version": 1, "a": 1, "a": 2}')
        try:
            load_json_strict(path)
        except RunnerError:
            return
        raise AssertionError('duplicate key was not rejected')

    @case
    def check_future_schema_rejected():
        path = os.path.join(tempfile.gettempdir(), 'future.json')
        with open(path, 'w', encoding='utf-8') as stream:
            stream.write('{"schema_version": 999}')
        try:
            load_json_strict(path)
        except StateInvalid:
            return
        raise AssertionError('future schema version was not rejected')

    @case
    def check_zero_tests_rejected():
        spec = {'argv': [sys.executable, '-c', 'pass'], 'cwd': '.',
                'kind': 'test'}
        result = run_command(repo, spec, 'SELF', 'selftest', None)
        expect(result.outcome == 'REJECTED',
               f'zero-test pass got {result.outcome}')

    @case
    def check_timeout_classification():
        spec = {'argv': ['/bin/sleep', '5'], 'cwd': '.', 'kind': 'command',
                'timeout': 1}
        result = run_command(repo, spec, 'SELF', 'selftest', None)
        expect(result.outcome == 'TIMEOUT',
               f'timeout got {result.outcome}')
        expect(result.note is not None, 'timeout lost its note')

    @case
    def check_nonzero_exit_failed():
        spec = {'argv': [sys.executable, '-c', 'raise SystemExit(3)'],
                'cwd': '.', 'kind': 'command'}
        result = run_command(repo, spec, 'SELF', 'selftest', None)
        expect(result.outcome == 'FAILED', f'exit 3 got {result.outcome}')
        expect(result.exit_code == 3, 'exit code lost')

    @case
    def check_pass_records_counts():
        script = ('import sys;'
                  'sys.stderr.write("test_one ... ok\\n");'
                  'sys.stderr.write("test_two ... fail\\n");'
                  'sys.stderr.write("Ran 2 tests in 0.001s\\n");'
                  'sys.stderr.write("FAILED (failures=1, errors=0, '
                  'skipped=0)\\n");'
                  'raise SystemExit(1)')
        spec = {'argv': [sys.executable, '-c', script], 'cwd': '.',
                'kind': 'test'}
        result = run_command(repo, spec, 'SELF', 'selftest', None)
        expect(result.outcome == 'FAILED', f'counts got {result.outcome}')
        expect(result.tests_executed == 2, f'executed {result.tests_executed}')
        expect(result.tests_failed == 1, f'failed {result.tests_failed}')

    @case
    def check_blocked_missing_executable():
        spec = {'argv': ['definitely-not-an-executable-9000', '--version'],
                'cwd': '.', 'requires': 'definitely-not-an-executable-9000'}
        try:
            run_command(repo, spec, 'SELF', 'selftest', None)
        except BlockedExternal as exc:
            expect('not found' in str(exc), f'blocked message {exc}')
            return
        raise AssertionError('missing executable did not block')

    @case
    def check_blocked_non_runnable_executor():
        remote = Executor({'id': 'dgx-linux',
                           'authorized_transport': 'ssh', 'capabilities': []})
        spec = {'argv': ['/bin/true'], 'cwd': '.', 'kind': 'command'}
        try:
            run_command(repo, spec, 'SELF', 'selftest', remote)
        except BlockedExternal as exc:
            expect('transport' in str(exc), f'missing transport in {exc}')
            return
        raise AssertionError('remote transport executor ran anyway')

    @case
    def check_missing_required_fields_manifest():
        try:
            run_command(repo, {'cwd': '.'}, 'SELF', 'selftest', None)
        except CommandError:
            return
        raise AssertionError('manifest missing argv was not rejected')

    ran = failures = 0
    for label, check in cases:
        ran += 1
        try:
            check()
        except AssertionError as exc:
            failures += 1
            print(f'FAIL: {label}\n  {exc}')
    return ran, failures


# -------------------------------------------------------------------- main --
def build_parser():
    parser = argparse.ArgumentParser(prog='run.py', description=__doc__.splitlines()[0])
    parser.add_argument('--repo', default=DEFAULT_REPO)
    parser.add_argument('--evidence', default=None)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('validate-state', help='verify the build state')
    sub.add_parser('selftest', help='run the built-in test suite')
    sub.add_parser('next', help='print the next dependency-ready task')
    p_task = sub.add_parser('task', help='run one task stage')
    p_task.add_argument('task_id')
    p_task.add_argument('--stage', default='narrow',
                       choices=('narrow', 'subsystem', 'controls'))
    p_task.add_argument('--dry-run', action='store_true')
    p_phase = sub.add_parser('phase', help='summarize a phase')
    p_phase.add_argument('phase_id')
    p_ladder = sub.add_parser('ladder', help='resolve the ladder levels')
    p_ladder.add_argument('levels')
    p_ladder.add_argument('--profile', required=True,
                         choices=('archive', 'lab-mesh', 'lab-oracle'))
    p_ladder.add_argument('--dry-run', action='store_true')
    p_eval = sub.add_parser('evaluate-candidate',
                            help='hash-verify an evidence manifest')
    p_eval.add_argument('--profile', required=True)
    p_eval.add_argument('--manifest', required=True)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    repo = Repo(args.repo, args.evidence)
    try:
        if args.command == 'validate-state':
            problems = validate_state(repo)
            for problem in problems:
                print(f'INVALID: {problem}', file=sys.stderr)
            return EXIT_STATE if problems else EXIT_OK
        if args.command == 'selftest':
            ran, failures = selftest(repo)
            print(f'Ran {ran} checks in selftest')
            if failures:
                print(f'FAILED (failures={failures})')
                return EXIT_FAILED
            print('OK')
            return EXIT_OK
        if args.command == 'next':
            nxt = next_task(repo)
            if nxt is None:
                print('no dependency-ready task remains; external gates may '
                      'still block completion', file=sys.stderr)
                return EXIT_BLOCKED
            print(nxt)
            return EXIT_OK
        if args.command == 'task':
            results = task_commands(repo, args.task_id, args.stage,
                                    dry_run=args.dry_run)
            worst = EXIT_OK
            for result in results:
                counts = (f'tests={result.tests_executed}/{result.tests_passed}'
                          if result.tests_executed is not None else 'tests=n/a')
                print(f'{result.id}: {result.outcome} exit={result.exit_code} '
                      f'{counts}')
                if result.outcome in ('FAILED', 'TIMEOUT', 'REJECTED'):
                    worst = EXIT_FAILED
            return worst
        if args.command == 'phase':
            for tid, status in phase_summary(repo, args.phase_id):
                print(f'{tid}: {status}')
            return EXIT_OK
        if args.command == 'ladder':
            plan = ladder(repo, args.levels, args.profile,
                         dry_run=args.dry_run)
            for level, value in plan.items():
                print(f'{level}: {value}')
            return EXIT_OK
        if args.command == 'evaluate-candidate':
            problems = evaluate_candidate(repo, args.profile, args.manifest)
            for problem in problems:
                print(f'INVALID: {problem}', file=sys.stderr)
            return EXIT_FAILED if problems else EXIT_OK
    except CommandError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return EXIT_USAGE
    except StateInvalid as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return EXIT_STATE
    except BlockedExternal as exc:
        print(f'BLOCKED: {exc}', file=sys.stderr)
        return EXIT_BLOCKED
    except RunnerError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return EXIT_RUNNER
    parser.error(f'unknown command {args.command!r}')
    return EXIT_USAGE


if globals().get('__name__') == '__main__':
    raise SystemExit(main(sys.argv[1:]))
