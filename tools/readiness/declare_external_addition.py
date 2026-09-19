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


NON_CONTENT_BASENAMES = ('.DS_Store',)
"""*** THE OPERATING SYSTEM'S OWN METADATA, NAMED -- NOT "WHATEVER `.gitignore` SAYS". ***

*MEASURED RISK, AND WHY THE OBVIOUS RULE IS THE WRONG ONE: a filter derived from `.gitignore` would apply `*.db`,
`*.apk`, `build/`, `__pycache__/` and more INSIDE the audit bundles -- and this repository's declared bundles DO
carry real content whose names those patterns cover. Five recorded paths are `*.db`:*
    AUDIT_FINAL_2026-09-15/.../swift-build/archive_light.db
    AUDIT_FINAL_2026-09-15/.../android-build/fixtures/{valid,malformed}.db
    AUDIT_FINAL_2026-09-15/.../fixtures/cache-valid/current/archive.db
*** EXCLUDING THEM WOULD CONVERT A RED CONTROL INTO A QUIET BLIND SPOT -- WORSE THAN THE FLAKE IT REPAIRS, because a
substitution inside audit evidence is exactly what this manifest existeth to catch. *** **So the rule is a NAMED
SET, not a derived one: the capture machine's own metadata, whose bytes belong to the Finder and not to the audit.**
*Justified by evidence already held: the audit's OWN `MANIFEST.sha256` recordeth zero `.DS_Store`; the repository
declareth it non-content at `.gitignore:89`; and the two recorded blobs were rewritten by macOS at an IDENTICAL
6148-byte size, which is the Finder's signature rather than any audit process's.*
"""


def ignored_paths(root: str) -> set:
    """The OPERATING SYSTEM'S metadata inside `root`, per `NON_CONTENT_BASENAMES`.

    **THE REPOSITORY IS STILL CONSULTED, BUT ONLY AS A SECOND OPINION** -- *the named basename must ALSO be one the
    repository declareth non-content, so the set can never silently widen past the declared rule and the repository
    stays the authority on what its own history considers noise.* **If git is unavailable the NAMED SET ALONE IS
    USED**, because a control that cannot ask the second question must not fall through to recording the Finder.
    """
    named = set(NON_CONTENT_BASENAMES)
    try:
        proc = subprocess.run(['git', 'ls-files', '--others', '--ignored', '--exclude-standard',
                               '--no-empty-directory'],
                              cwd=root, capture_output=True, text=True)
    except OSError:
        return named
    if proc.returncode != 0:
        return named
    declared = {ln.strip() for ln in proc.stdout.splitlines() if ln.strip()}
    return {name for name in named if name in declared}


def is_non_content(key: str, non_content: set) -> bool:
    """Whether `key` (a repository-relative path) is the operating system's metadata.

    **MATCHED BY BASENAME AT ANY DEPTH:** *a `.DS_Store` inside a *bundle* directory is the same Finder artefact as one
    at the root, and the Finder writeth it wherever a window is opened.*
    """
    return os.path.basename(key.replace(os.sep, '/')) in non_content


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
