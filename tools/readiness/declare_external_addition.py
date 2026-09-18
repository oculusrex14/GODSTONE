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


def build(root: str = ROOT) -> dict:
    entries: dict[str, dict] = {}
    for rel in declared_paths():
        base = os.path.join(root, rel)
        if not os.path.isdir(base):
            continue
        files = {}
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                key = os.path.relpath(full, root)
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
