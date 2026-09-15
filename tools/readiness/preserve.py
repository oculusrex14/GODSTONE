#! /usr/bin/env python3
"""GODSTONE builder preservation toolkit (T01).

Inventories the planning-baseline checkout and copies work-in-progress into a
private sibling evidence directory, verifying every byte by SHA-256 before any
worktree is created. Never mutates the source checkout.

BaselineInventory shape (per T01 spec):
  head, parent, branch, trackedPatchHash,
  untrackedFiles[{path,size,sha256}], ignoredFixtureFiles, preservationRoot
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

RELEVANT_IGNORED_FIXTURE_PREFIXES = (
    'content/', 'crypto/', 'safety/', 'meshsim/', 'wire/', 'dist/',
    'artifacts/', 'scripts/', 'ci/', 'provenance.json',
)
BUILD_NOISE_MARKERS = (
    '__pycache__/', '.pyc', '/build/', '.gradle/', '.kotlin/',
    'node_modules/', '.venv/', 'xcuserdata', 'DerivedData',
)
ALLOWED_STATUSES = (
    'PENDING', 'IN_PROGRESS', 'COMPLETE', 'FAILED_RETRYABLE',
    'BLOCKED_EXTERNAL', 'BLOCKED_HARDWARE', 'BLOCKED_ARCHITECTURE',
)


class PreservationError(RuntimeError):
    """Raised when a preservation or verification step cannot be trusted."""


#: Reviewed additions to the ORIGINAL checkout made by other parties after the T01
#: baseline was captured. GS-CTRL-002: the inventory must be EXPLICIT and CORRECT
#: without weakening the comparison -- the live tree must equal the saved baseline
#: PLUS exactly these declared additions, line for line.
DECLARATIONS_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    'docs', 'production-readiness', 'ORIGINAL_CHECKOUT_ADDITIONS.json')


def load_declared_additions(path: str = '') -> list[dict]:
    """The reviewed external additions, or an empty list when none is declared."""
    path = path or DECLARATIONS_PATH
    if not os.path.isfile(path):
        return []
    with open(path, encoding='utf-8') as stream:
        document = json.load(stream)
    additions = []
    for entry in document.get('additions', []):
        if not entry.get('path') or 'entries' not in entry:
            raise PreservationError(f'declaration entry incomplete: {entry!r}')
        additions.append(dict(entry))
    return additions


def _declared_prefixes(additions: list[dict]) -> tuple[str, ...]:
    return tuple(entry['path'].rstrip('/') + '/' for entry in additions)


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        while True:
            block = stream.read(1 << 20)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def _git(cwd: str, argv: list[str]) -> str:
    proc = subprocess.run(['git', *argv], cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise PreservationError(f'git {" ".join(argv)} failed: {proc.stderr.strip()}')
    return proc.stdout


def classify_ignored(root: str, paths: list[str]) -> tuple[list[str], list[str]]:
    """Split ignored paths into relevant fixtures vs build noise.

    Deliberately conservative: only allowlisted prefixes qualify, and path
    lookalikes that are actually build artifacts stay noise.
    """
    relevant: list[str] = []
    noise: list[str] = []
    for path in paths:
        normalized = path.replace(os.sep, '/')
        if any(marker in normalized for marker in BUILD_NOISE_MARKERS):
            noise.append(path)
            continue
        if normalized.startswith(RELEVANT_IGNORED_FIXTURE_PREFIXES):
            full = os.path.join(root, path)
            if os.path.isfile(full):
                relevant.append(path)
                continue
        noise.append(path)
    return relevant, noise


def atomic_write_json(path: str, payload: object) -> None:
    """Sorted, stable, atomic JSON persistence with fsync (section 25 rules)."""
    directory = os.path.dirname(path) or '.'
    os.makedirs(directory, exist_ok=True)
    tmp = f'{path}.tmp.{os.getpid()}'
    with open(tmp, 'w', encoding='utf-8') as stream:
        json.dump(payload, stream, sort_keys=True, indent=2, ensure_ascii=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)


def build_inventory(root: str, additions: list[dict] | None = None) -> dict:
    """Collect the BaselineInventory structure from a live checkout.

    Declared external additions are EXCLUDED from the copied work-in-progress (they
    are not builder work), and their live entry counts are MEASURED and recorded so
    that verification can require the exact arithmetic.
    """
    root = os.path.abspath(root)
    head = _git(root, ['rev-parse', 'HEAD']).strip()
    parent = _git(root, ['rev-parse', 'HEAD^']).strip()
    branch = _git(root, ['branch', '--show-current']).strip()
    modified = sorted(
        _git(root, ['diff', '--name-only', 'HEAD']).splitlines())
    untracked = sorted(
        _git(root, ['ls-files', '--others', '--exclude-standard']).splitlines())
    additions = load_declared_additions() if additions is None else additions
    prefixes = _declared_prefixes(additions)
    untracked = [path for path in untracked
                 if not path.replace(os.sep, '/').startswith(prefixes)]
    ignored_all = sorted(
        _git(root, ['ls-files', '--others', '--ignored',
                   '--exclude-standard']).splitlines())
    relevant, noise = classify_ignored(root, ignored_all)
    patch_proc = subprocess.run(
        ['git', 'diff', '--binary', 'HEAD'], cwd=root, capture_output=True)
    if patch_proc.returncode != 0:
        raise PreservationError('git diff --binary HEAD failed')
    patch_hash = hashlib.sha256(patch_proc.stdout).hexdigest()
    status = _git(root, ['status', '--porcelain=v1', '--untracked-files=all'])
    declared: list[dict] = []
    for entry in additions:
        prefix = entry['path'].rstrip('/') + '/'
        lines = [line for line in status.splitlines()
                 if line[3:].startswith(prefix) or line[3:].strip() == entry['path'].rstrip('/')]
        declared.append({
            'path': entry['path'],
            'kind': entry.get('kind'),
            'entries': len(lines),
            'declared_entries': entry['entries'],
            'read_only': entry.get('read_only', True),
            'copied_into_evidence': False,
            'added_by': entry.get('added_by'),
            'provenance': entry.get('provenance'),
            'disclosed_by': entry.get('disclosed_by', []),
            'measured_matches_declaration': len(lines) == entry['entries'],
            'status_codes': sorted({line[:2] for line in lines}),
        })

    def file_entries(paths: list[str], extra: dict | None = None) -> list[dict]:
        entries = []
        for path in paths:
            full = os.path.join(root, path)
            if not os.path.isfile(full):
                continue
            entry = {'path': path,
                     'size': os.path.getsize(full),
                     'sha256': sha256_file(full)}
            if extra:
                entry.update(extra)
            entries.append(entry)
        return sorted(entries, key=lambda e: e['path'])

    return {
        'schema_version': 1,
        'head': head,
        'parent': parent,
        'branch': branch,
        'tracked_patch_hash': patch_hash,
        'porcelain_entries': len(status.splitlines()),
        'porcelain_baseline_entries': len(status.splitlines())
                                     - sum(entry['entries'] for entry in declared),
        'declared_additions': declared,
        'tracked_wip_files': file_entries(modified),
        'untracked_files': file_entries(untracked),
        'ignored_fixture_files': file_entries(
            relevant, {'classification': 'debug_or_past_run_fixture'}),
        'ignored_noise_count': len(noise),
    }


def capture_raw_probes(root: str, evidence_dir: str) -> None:
    """Persist the raw command probes named by the T01 command list."""
    raw = os.path.join(evidence_dir, 'raw')
    os.makedirs(raw, exist_ok=True)
    # GS-CTRL-002: the baseline is IMMUTABLE. A capture that would overwrite an
    # existing status-before.txt is written BESIDE it instead, so the original
    # baseline keepeth its force for ever.
    status_name = 'status-before.txt'
    if os.path.isfile(os.path.join(evidence_dir, 'raw', status_name)):
        status_name = 'status-recaptured.txt'
    probes = {
        status_name: ['status', '--porcelain=v1', '--untracked-files=all'],
        'head.txt': ['rev-parse', 'HEAD'],
        'parent.txt': ['rev-parse', 'HEAD^'],
        'head-fuller.txt': ['show', '--no-patch', '--format=fuller', 'HEAD'],
        'remote-tips.txt': ['for-each-ref', 'refs/remotes'],
        'tracked-patch.bin': None,
    }
    for name, argv in probes.items():
        target = os.path.join(raw, name)
        if argv is None:
            proc = subprocess.run(['git', 'diff', '--binary', 'HEAD'],
                                  cwd=root, capture_output=True)
            if proc.returncode != 0:
                raise PreservationError('tracked probe: git diff failed')
            with open(target, 'wb') as stream:
                stream.write(proc.stdout)
        else:
            with open(target, 'w', encoding='utf-8') as stream:
                stream.write(_git(root, argv))


def copy_preservation(root: str, evidence_dir: str, inventory: dict) -> list[str]:
    """Copy WIP into the evidence root and verify every byte immediately."""
    dest = os.path.join(evidence_dir, 'wip')
    os.makedirs(dest, exist_ok=True)
    copied: list[str] = []
    for entry in [*inventory['untracked_files'], *inventory['ignored_fixture_files']]:
        src = os.path.join(root, entry['path'])
        dst = os.path.join(dest, entry['path'])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        if sha256_file(dst) != entry['sha256']:
            raise PreservationError(f'copy verify mismatch: {entry["path"]}')
        copied.append(entry['path'])
    patch_src = os.path.join(evidence_dir, 'raw', 'tracked-patch.bin')
    patch_dst = os.path.join(evidence_dir, 'tracked-patch.bin')
    if not os.path.isfile(patch_src):
        raise PreservationError('raw tracked patch missing before promotion')
    shutil.copy2(patch_src, patch_dst)
    if sha256_file(patch_dst) != inventory['tracked_patch_hash']:
        raise PreservationError('tracked patch hash drifted between capture and copy')
    return copied


def verify_preservation(root: str, evidence_dir: str, inventory: dict) -> list[str]:
    """Independent re-verification of the copy; empty list means intact."""
    failures: list[str] = []
    for entry in [*inventory['untracked_files'], *inventory['ignored_fixture_files']]:
        dst = os.path.join(evidence_dir, 'wip', entry['path'])
        if not os.path.isfile(dst):
            failures.append(f'missing copy: {entry["path"]}')
            continue
        if os.path.getsize(dst) != entry['size']:
            failures.append(f'size mismatch: {entry["path"]}')
        elif sha256_file(dst) != entry['sha256']:
            failures.append(f'hash mismatch: {entry["path"]}')
    patch = os.path.join(evidence_dir, 'tracked-patch.bin')
    if not os.path.isfile(patch):
        failures.append('missing tracked patch copy')
    elif sha256_file(patch) != inventory['tracked_patch_hash']:
        failures.append('tracked patch hash drift')
    live = _git(root, ['status', '--porcelain=v1', '--untracked-files=all'])
    additions = inventory.get('declared_additions')
    if additions is None:
        additions = [{'path': entry['path'], 'declared_entries': entry['entries']}
                     for entry in load_declared_additions()]
    stripped: list[str] = []
    for entry in additions:
        prefix = entry['path'].rstrip('/') + '/'
        matched = [line for line in live.splitlines()
                   if line[3:].startswith(prefix)
                   or line[3:].strip() == entry['path'].rstrip('/')]
        expected = entry.get('declared_entries', entry.get('entries'))
        if not os.path.exists(os.path.join(root, entry['path'])):
            failures.append(f'declared addition absent: {entry["path"]}')
        if len(matched) != expected:
            failures.append(
                f'declared addition drifted: {entry["path"]} nameth {expected} entries, '
                f'the live tree carrieth {len(matched)} -- the declaration is a MEASURED '
                f'fact, not a blanket exemption')
        stripped.extend(matched)
    saved = os.path.join(evidence_dir, 'raw', 'status-before.txt')
    if os.path.isfile(saved):
        with open(saved, encoding='utf-8') as stream:
            baseline = stream.read()
        remainder = [line for line in live.splitlines() if line not in stripped]
        if remainder != baseline.splitlines():
            failures.append(
                'original checkout status changed during preservation: the live tree '
                'minus the declared additions must equal the saved baseline line for line '
                f'(live-minus-declared={len(remainder)}, baseline='
                f'{len(baseline.splitlines())})')
    return failures


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog='preserve.py')
    parser.add_argument('root')
    parser.add_argument('evidence_dir')
    args = parser.parse_args(argv[1:])
    root = os.path.abspath(args.root)
    evidence = os.path.abspath(args.evidence_dir)
    started = time.time()
    capture_raw_probes(root, evidence)
    inventory = build_inventory(root)
    inventory['preservation_root'] = evidence
    copy_preservation(root, evidence, inventory)
    failures = verify_preservation(root, evidence, inventory)
    inventory['preservation_seconds'] = round(time.time() - started, 3)
    atomic_write_json(os.path.join(evidence, 'inventory.json'), inventory)
    if failures:
        for failure in failures:
            print(f'FAIL {failure}', file=sys.stderr)
        return 1
    print(json.dumps({
        'ok': True,
        'head': inventory['head'],
        'untracked_copied': len(inventory['untracked_files']),
        'fixtures_copied': len(inventory['ignored_fixture_files']),
        'porcelain_entries': inventory['porcelain_entries'],
    }, indent=2))
    return 0


if globals().get('__name__') == '__main__':
    raise SystemExit(main(sys.argv))
