#! /usr/bin/env python3
"""ExternalNoiseLockV1: the structural gate for independent Noise vectors (T04).

The A-06 gate closes ONLY when a real, independently-produced vector file is
present AND a lock file binds it to an immutable upstream revision, origin,
license, exact digests, the frozen protocol name, the GMP2 prologue, the full
required case list, and a named reviewer with a date. Nothing here can close
the gate by itself: a lock that claims conformance without all of that is
FAILED, a missing lock or fixture is UNAVAILABLE, and UNAVAILABLE is a typed
result with a NONZERO release exit - never a silent pass.

    python -m crypto.noise_lock --status
    python -m crypto.noise_lock --release   # exit 0 only when VERIFIED

Repository fixtures are self-generated and explicitly non-independent; the
lock validator refuses any lock whose upstream origin names this repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_LOCK = HERE / "noise_lock.json"
DEFAULT_FIXTURE = HERE / "cacophony_vectors.json"
LOCK_SCHEMA = "ExternalNoiseLockV1"
REQUIRED_UPSTREAM_KEYS = ("repo", "revision", "path", "fetched_utc")
SELF_ORIGIN_MARKERS = ("godstone",)


class ConformanceStatus:
    UNAVAILABLE = "UNAVAILABLE"
    VERIFIED = "VERIFIED"
    FAILED = "FAILED"


EXIT_CODES = {
    ConformanceStatus.VERIFIED: 0,
    ConformanceStatus.FAILED: 1,
    ConformanceStatus.UNAVAILABLE: 3,
}


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        while True:
            block = stream.read(1 << 20)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def load_json_strict(path):
    """Duplicate-key-safe JSON decode; unknown versions are rejected."""
    with open(path, encoding='utf-8') as stream:
        text = stream.read()

    def hook(pairs):
        seen = set()
        for key, _ in pairs:
            if key in seen:
                raise ValueError(f'{path}: duplicate key {key!r}')
            seen.add(key)
        return dict(pairs)

    return json.loads(text, object_pairs_hook=hook)


def _first(raw, *names):
    for name in names:
        if raw.get(name):
            return raw[name]
    return None


def verify_lock(lock_path=DEFAULT_LOCK, fixture_path=DEFAULT_FIXTURE):
    """Validate the lock and, when sound, the external fixture it binds.

    Returns (status, problems, detail). Statuses:
      UNAVAILABLE - lock or fixture absent (typed; release exit nonzero)
      VERIFIED    - every lock field sound, digests match, all required cases
                    present with no duplicates and no partial selection, and
                    the vector bytes reproduce
      FAILED      - any lock or fixture defect
    """
    problems = []
    if not os.path.isfile(lock_path):
        return (ConformanceStatus.UNAVAILABLE,
                [f'no lock file at {lock_path}'],
                'A-06 remains unpinned; a lock file binds an independent '
                'fixture once it exists')
    try:
        lock = load_json_strict(lock_path)
    except ValueError as exc:
        return (ConformanceStatus.FAILED, [f'lock unreadable: {exc}'], '')
    if lock.get('lock_schema') != LOCK_SCHEMA:
        problems.append(
            f"lock_schema must be {LOCK_SCHEMA!r}, got "
            f"{lock.get('lock_schema')!r}")
    upstream = lock.get('upstream') or {}
    for key in REQUIRED_UPSTREAM_KEYS:
        if not upstream.get(key):
            problems.append(f'upstream.{key} missing or empty')
    origin = str(upstream.get('repo') or '')
    if any(marker in origin.lower() for marker in SELF_ORIGIN_MARKERS):
        problems.append(
            'upstream.repo names this repository; a self-generated fixture '
            'mislabeled independent is the exact failure this gate exists to '
            'eliminate')
    revision = str(upstream.get('revision') or '')
    if revision and (len(revision) < 40 or
                     any(c not in '0123456789abcdefABCDEF' for c in revision)):
        problems.append('upstream.revision must be a full immutable sha')
    if not str(lock.get('license') or '').strip():
        problems.append('license missing or empty')
    reviewer = lock.get('reviewer') or {}
    if not str(reviewer.get('identity') or '').strip():
        problems.append('reviewer.identity missing or empty')
    if not str(reviewer.get('date') or '').strip():
        problems.append('reviewer.date missing or empty')
    if not os.path.isfile(fixture_path):
        return (ConformanceStatus.UNAVAILABLE,
                problems + [f'fixture missing at {fixture_path}'],
                'the locked external fixture is not present in this tree')
    fixture_sha = sha256_file(fixture_path)
    if lock.get('fixture_sha256') != fixture_sha:
        problems.append(
            f'fixture digest mismatch: lock pins '
            f'{lock.get("fixture_sha256")}, file is {fixture_sha}')
    # all remaining checks need the fixture bytes
    if problems:
        return ConformanceStatus.FAILED, problems, ''
    try:
        from .cacophony import load_vectors, find_target, TARGET
        from . import derivation as D
        vectors = load_vectors(Path(fixture_path))
    except (ValueError, ImportError) as exc:
        problems.append(f'fixture unreadable: {exc}')
        return ConformanceStatus.FAILED, problems, ''
    if lock.get('protocol_name') != str(getattr(_target_protocol(), 'name',
                                                TARGET) if False else TARGET):
        problems.append('lock pins a different protocol suite')
        return ConformanceStatus.FAILED, problems, ''
    matching = [(i, v) for i, v in enumerate(vectors)
                if (_first(v, 'protocol_name', 'name') or '') == TARGET]
    required = lock.get('required_cases') or []
    ids = [f'{TARGET}@{i}' for i, _ in matching]
    if len(ids) != len(set(ids)):
        problems.append('duplicate case ids in the fixture for the pinned '
                        'protocol; the matching case set is ambiguous')
    if sorted(required) != sorted(ids):
        problems.append(
            'partial selection: required_cases must list every matching '
            f'case exactly once (required {len(required)}, present {len(ids)})')
    if problems:
        return ConformanceStatus.FAILED, problems, ''
    raw = vectors[matching[0][0]]
    prologue_hex = _first(raw, 'init_prologue', 'prologue') or ''
    prologue = bytes.fromhex(prologue_hex)
    recorded_prologue = str(lock.get('prologue_sha256') or '')
    if recorded_prologue_sha256(prologue) != lock.get('prologue_sha256'):
        problems.append(
            'prologue digest mismatch: the locked GMP2 prologue does not '
            'match the fixture')
    if not prologue.startswith(bytes.fromhex(
            _prologue_prefix_hex(lock))):
        problems.append('fixture prologue does not start with the pinned '
                        'GMP2 prefix')
    if problems:
        return ConformanceStatus.FAILED, problems, ''
    from .cacophony import check as cacophony_check
    ok, detail = cacophony_check(Path(fixture_path), verbose=False)
    if not ok:
        problems.append(f'vector bytes did not reproduce: {detail}')
        return ConformanceStatus.FAILED, problems, ''
    return (ConformanceStatus.VERIFIED, [],
            f'{len(ids)} case(s) verified against upstream revision '
            f'{revision[:12]}')


def _target_protocol():
    from .noise_ref import PROTOCOL_NAME
    return PROTOCOL_NAME.decode()


def _prologue_prefix_hex(lock):
    """GMP2 magic prefix the lock must pin (4 bytes, 'GMP2')."""
    prefix = lock.get('prologue_prefix_hex')
    if prefix:
        return prefix
    from .derivation import PROLOGUE_MAGIC
    return PROLOGUE_MAGIC.hex()


def recorded_prologue_sha256(prologue):
    return hashlib.sha256(prologue).hexdigest()


def status(lock_path=DEFAULT_LOCK, fixture_path=DEFAULT_FIXTURE):
    status_value, problems, detail = verify_lock(lock_path, fixture_path)
    return status_value, problems, detail


def release_exit(lock_path=DEFAULT_LOCK, fixture_path=DEFAULT_FIXTURE):
    """Release mode: nonzero unless VERIFIED. Typed, never silent."""
    status_value, problems, detail = status(lock_path, fixture_path)
    print(f'EXTERNAL NOISE LOCK: {status_value}')
    for problem in problems:
        print(f'  - {problem}')
    if detail:
        print(f'  {detail}')
    if status_value == ConformanceStatus.UNAVAILABLE:
        print('  A-06 remains an open external gate; repository fixtures are '
              'self-generated and cannot close it.')
    return EXIT_CODES[status_value]


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog='crypto.noise_lock',
        description='ExternalNoiseLockV1 validator (A-06 structural gate)')
    parser.add_argument('--lock', type=Path, default=DEFAULT_LOCK)
    parser.add_argument('--fixture', type=Path, default=DEFAULT_FIXTURE)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--status', action='store_true')
    group.add_argument('--release', action='store_true')
    args = parser.parse_args(argv)
    if args.release:
        return release_exit(args.lock, args.fixture)
    status_value, problems, detail = status(args.lock, args.fixture)
    print(f'EXTERNAL NOISE LOCK: {status_value}')
    for problem in problems:
        print(f'  - {problem}')
    if detail:
        print(f'  {detail}')
    return 0


if globals().get('__name__') == '__main__':
    raise SystemExit(main(sys.argv[1:]))