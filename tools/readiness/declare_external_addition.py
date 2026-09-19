#!/usr/bin/env python3
"""Record EXACT PATHS AND HASHES for a declared external addition.

    python3 tools/readiness/declare_external_addition.py --write
    python3 tools/readiness/declare_external_addition.py --check

WHY THIS EXISTS
---------------
`ORIGINAL_CHECKOUT_ADDITIONS.json` declareth external additions to the original
checkout, and `preserve.py` verifieth that the live tree equalleth the saved
baseline PLUS those additions. **BUT IT COMPARED COUNTS -- and a count is blind
to a SUBSTITUTION: swapping one file's CONTENTS inside a declared bundle, or
swapping one file for another of the same size, leaveth the count identical and
the verification GREEN.**

`08_evidence_and_test_integrity_report.md` nameth the remedy in its own words:
*"Record later legitimate additions in a new independently reviewed manifest
with EXACT PATHS/HASHES, **not a blanket exclusion of the entire audit
directory**."* **A COUNT IS THE BLANKET EXCLUSION; A HASH MANIFEST IS THE
RECORD.** This script writeth and checketh that manifest.

THE LAW, AND IT HATH THREE CASES -- *because the folders are written by ANOTHER
PARTY's process and keep growing:*
  * a RECORDED path whose bytes CHANGED   -> **FAILS** (tampering, not growth);
  * a RECORDED path now ABSENT            -> **FAILS** (removed audit evidence);
  * a NEW path not in the manifest        -> **PERMITTED** (growth, by the
    `grows` rule the declaration already carrieth).
*So the manifest is a FLOOR ON CONTENT rather than a frozen list, which is the
same shape the count-floor already had -- one layer more precise.*
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys

ROOT = '/Users/oculus/Projects/GODSTONE'
DECL = os.path.join(ROOT, 'docs', 'production-readiness', 'ORIGINAL_CHECKOUT_ADDITIONS.json')
MANIFEST = os.path.join(ROOT, 'docs', 'production-readiness', 'ORIGINAL_CHECKOUT_ADDITIONS.hashes.json')


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def declared_paths() -> list[str]:
    with open(DECL, encoding='utf-8') as fh:
        doc = json.load(fh)
    return [e['path'] for e in doc.get('additions', [])]


def ignored_paths(root: str) -> set:
    """The paths `root`'s own repository declareth NON-CONTENT.

    *** THE CONTENT MANIFEST MUST ENUMERATE CONTENT. *** *A recorded sha256 over an IGNORED file can never be kept:
    the operating system rewriteth it at will (macOS rewrote both recorded `.DS_Store` blobs with an identical
    6148-byte size), and a fresh clone carrieth it not at all -- so the court would redden over a clean checkout of
    its own commit AND over a meaningless substitution alike.* **MEASURED: `declare_external_addition.py --check`
    reported `2 failure(s)` for exactly this, two Finder artefacts the repository had already declared non-content.**

    *The answer is the repository's OWN ruling, not a hand-kept list: ASK GIT.* **A path `.gitignore`d is, by the
    record's own definition, not evidence.** *If git is unavailable the set is empty and behaviour is unchanged
    -- a control that cannot ask the question must not silently invent an answer, so it falls back to recording
    everything exactly as before.*
    """
    try:
        proc = subprocess.run(['git', 'ls-files', '--others', '--ignored', '--exclude-standard',
                               '--directory', '--no-empty-directory'],
                              cwd=root, capture_output=True, text=True)
    except OSError:
        return set()
    if proc.returncode != 0:
        return set()
    return {ln.strip().rstrip('/') for ln in proc.stdout.splitlines() if ln.strip()}


def is_non_content(key: str, ignored: set) -> bool:
    """Whether `key` (a repository-relative path) is declared non-content.

    **MATCHED AT ANY DEPTH**, because git reporteth a whole ignored DIRECTORY as one entry: a `.DS_Store` inside a
    bundle whose parent is ignored must be excluded the same way a bare `.DS_Store` is.
    """
    normalized = key.replace(os.sep, '/').strip('/')
    if not ignored:
        return False
    parts = normalized.split('/')
    return any('/'.join(parts[:i + 1]) in ignored or parts[i] in ignored
               for i in range(len(parts)))


def build(root: str = ROOT) -> dict:
    entries: dict[str, dict] = {}
    ignored = ignored_paths(root)
    for rel in declared_paths():
        base = os.path.join(root, rel)
        if not os.path.isdir(base):
            continue
        files = {}
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                key = os.path.relpath(full, root)
                if is_non_content(key, ignored):
                    continue  # THE CAPTURE MACHINE IS NOT PART OF THE EVIDENCE (see `ignored_paths`)
                files[key] = {'sha256': sha256_file(full), 'size': os.path.getsize(full)}
        entries[rel] = files
    return entries


def check(root: str = ROOT) -> list[str]:
    if not os.path.isfile(MANIFEST):
        return ['the hash manifest is absent -- a declared addition carrieth no content record']
    with open(MANIFEST, encoding='utf-8') as fh:
        recorded = json.load(fh).get('files', {})
    failures: list[str] = []
    for rel, files in recorded.items():
        for key, meta in files.items():
            full = os.path.join(root, key)
            if not os.path.isfile(full):
                failures.append(f'declared addition REMOVED a recorded file: {key}')
                continue
            if os.path.getsize(full) != meta['size'] or sha256_file(full) != meta['sha256']:
                failures.append(
                    f'declared addition CHANGED a recorded file: {key} -- the manifest recordeth '
                    f'{meta["sha256"][:12]}… ({meta["size"]} bytes) and the tree carrieth '
                    f'{sha256_file(full)[:12]}… ({os.path.getsize(full)} bytes). *Growth is adding files; '
                    f'a changed RECORDED file is a substitution, not growth.*')
    return failures


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--root', default=ROOT)
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args(argv)
    if a.write:
        entries = build(a.root)
        total = sum(len(v) for v in entries.values())
        with open(MANIFEST, 'w', encoding='utf-8') as fh:
            json.dump({
                'kind': 'EXTERNAL_ADDITION_CONTENT_MANIFEST',
                'rule': ('Every recorded path must exist with the recorded sha256. NEW paths are PERMITTED '
                         '(the folders are written by another party\'s process and grow); a CHANGED or REMOVED '
                         'recorded path FAILS.'),
                'source': 'docs/production-readiness/ORIGINAL_CHECKOUT_ADDITIONS.json',
                'files': entries,
            }, fh, indent=1, sort_keys=True)
            fh.write('\n')
        print(f'wrote {MANIFEST}: {len(entries)} bundle(s), {total} file hash(es)')
        return 0
    if a.check:
        failures = check(a.root)
        for f in failures:
            print('::error::' + f)
        print(f'content manifest: {len(failures)} failure(s)')
        return 1 if failures else 0
    ap.print_help()
    return 2


if __name__ == '__main__':
    sys.exit(main())
