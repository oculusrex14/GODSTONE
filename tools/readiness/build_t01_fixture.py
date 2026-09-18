#!/usr/bin/env python3
"""Reconstruct the T01 preservation fixture, and run its court against it.

    python3 tools/readiness/build_t01_fixture.py --build --out /tmp/t01fixture
    python3 tools/readiness/build_t01_fixture.py --verify --fixture /tmp/t01fixture/godstone

WHY THIS EXISTS
---------------
`test_t01.py` is NOT a generic clean-candidate court. Its own README sayeth so, and
`godstone-audit/verification/NEXT_EXECUTION.md` step 3 sayeth it again:

    *"The T01 tests are not generic clean-candidate tests. They require their original
    preservation inventory, tracked patch, copied WIP and historical status/addition
    records. **Reconstruct those in an isolated fixture.** `GODSTONE_ROOT` must point to
    that reconstructed original fixture, **not automatically to the candidate or the
    authoritative original**."*

So running it against a live working tree asks a question it was never built to answer:
*a snapshot of commit X cannot equal a tree 1000+ commits later, because files that were
work-in-progress at capture have since been COMMITTED and so have left the porcelain.*

WHAT IT BUILDS, AND FROM WHAT
-----------------------------
Everything comes from the retention directory `<T01>/inventory.json` NAMES -- the pinned
head, the parent, the branch, the tracked patch and the WIP copies. **NOTHING IS
INVENTED:** if a material is missing the reconstruction REFUSES rather than proceeding
with a partial fixture, because *a fixture that cannot be shown to reproduce the
baseline is not a reconstruction, it is a different tree wearing the same name.*

THE ACCEPTANCE CRITERION, WHICH IS THE WHOLE POINT
--------------------------------------------------
The reconstructed tree's porcelain must be **BYTE-IDENTICAL** to `<T01>/raw/status-before.txt`.
The script asserteth that BEFORE reporting success, and exits non-zero if it differs --
*so "the fixture was built" and "the fixture reproduces the preserved state" are the same
statement, and neither is claimed on the other's behalf.*
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

DEFAULT_REPO = '/Users/oculus/Projects/GODSTONE'
DEFAULT_EVIDENCE = os.path.join(os.path.dirname(DEFAULT_REPO), 'GODSTONE_BUILDER_EVIDENCE', 'T01')


def run(args, cwd=None, check=True):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit('%s failed: %s%s' % (' '.join(args), r.stdout, r.stderr))
    return r


def load(evidence):
    with open(os.path.join(evidence, 'inventory.json'), encoding='utf-8') as fh:
        return json.load(fh)


def require(evidence):
    """Every material the reconstruction needeth, or a REFUSAL naming what is missing."""
    missing = []
    for name in ('inventory.json', 'tracked-patch.bin', 'raw/status-before.txt', 'wip'):
        if not os.path.exists(os.path.join(evidence, name)):
            missing.append(name)
    if missing:
        raise SystemExit(
            'REFUSING to build a partial fixture -- these materials are absent: %s\n'
            '*"missing configuration is not a reason to fabricate an inventory."*' % ', '.join(missing))


def build(repo, evidence, out):
    require(evidence)
    inv = load(evidence)
    dest = os.path.join(out, 'godstone')
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(out, exist_ok=True)

    run(['git', 'clone', '--no-hardlinks', '--no-checkout', '--quiet', repo, dest])
    run(['git', 'checkout', '--detach', inv['head'], '--quiet'], cwd=dest)
    # THE TRACKED WIP, reapplied -- the patch recordeth exactly what the tree carried at capture.
    run(['git', 'apply', os.path.join(evidence, 'tracked-patch.bin')], cwd=dest)
    # THE UNTRACKED WIP, restored at the same relative paths.
    shutil.copytree(os.path.join(evidence, 'wip'), dest, dirs_exist_ok=True)
    # THE BRANCH, because the inventory RECORDED one and the court asserteth it.
    run(['git', 'checkout', '-B', inv['branch'], '--quiet'], cwd=dest)
    return dest, inv


def add_declared(repo, dest, inv):
    """THE DECLARED ADDITIONS, copied in ONLY AFTER the baseline has been verified.

    **THE ORDER MATTERS AND A FIRST DRAFT GOT IT WRONG:** copying the bundle in before verifying made the check
    compare a tree WITH the addition against a baseline WITHOUT it, so the script refused its own correct fixture.
    *The baseline recordeth the tree as it stood when preservation was captured -- which is BEFORE the other party's
    folder appeared -- so the reproduction check belongeth on the pre-declaration tree, and the additions are what the
    COURT needeth to find present.* The two checks answer different questions and must not be conflated.
    """
    # *** NO DECLARATION FILE IS COPIED INTO THE FIXTURE, AND THE REASON IS THE ROUND-663 DESIGN. ***
    #
    # `declarations_path_for(root)` resolveth the declaration UNDER THE TREE BEING VERIFIED. **SO A FIXTURE CARRIETH
    # NONE, AND THEREFORE INHERITS NOTHING** -- which is what stoppeth this repository's declarations from judging a
    # tree they were never about. *The fixture instead reconstructs the PRESERVED state, whose declared additions are
    # exactly the ones its own inventory carrieth.*
    #
    # **TWO EARLIER DRAFTS GOT THIS WRONG, EACH CAUGHT BY A COURT ARM:**
    #   * copying the file in UNTRACKED made it an undeclared difference (measured: remainder 157 vs baseline 156, the
    #     single extra being exactly that file);
    #   * committing it MOVED `HEAD`, so `test_inventory_matches_live_git_facts` failed with the fixture's new SHA
    #     against the inventory's recorded `b5c3d3d3`.
    # **AND THE FIX IS NEITHER -- IT IS NOT TO COPY IT AT ALL.**
    for entry in inv.get('declared_additions', []):
        src = os.path.join(repo, entry['path'])
        if os.path.isdir(src) and not os.path.exists(os.path.join(dest, entry['path'])):
            shutil.copytree(src, os.path.join(dest, entry['path']))
    return dest


def verify(dest, evidence, inv):
    """THE ACCEPTANCE CRITERION: the reconstructed porcelain must equal the saved baseline."""
    live = run(['git', 'status', '--porcelain=v1', '--untracked-files=all'], cwd=dest).stdout.splitlines()
    with open(os.path.join(evidence, 'raw', 'status-before.txt'), encoding='utf-8') as fh:
        saved = fh.read().splitlines()
    same = set(live) == set(saved)
    print('reconstructed head   : %s (branch %s)' % (inv['head'][:12], run(['git', 'branch', '--show-current'], cwd=dest).stdout.strip()))
    print('reconstructed porcelain: %d entries' % len(live))
    print('saved baseline         : %d entries' % len(saved))
    print('IDENTICAL              : %s' % same)
    if not same:
        extra, gone = sorted(set(live) - set(saved))[:5], sorted(set(saved) - set(live))[:5]
        print('  extra   : %s' % extra)
        print('  missing : %s' % gone)
        print('\n*** THE FIXTURE DOES NOT REPRODUCE THE PRESERVED STATE -- and a fixture that cannot be '
              'shown to reproduce it is a different tree wearing the same name. ***')
        return 1
    print('\n*** THE RECONSTRUCTED TREE REPRODUCES THE PRESERVED STATE EXACTLY. ***')
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--repo', default=DEFAULT_REPO)
    ap.add_argument('--evidence', default=DEFAULT_EVIDENCE)
    ap.add_argument('--out', default='/tmp/t01fixture', help='where to build (--build)')
    ap.add_argument('--fixture', help='an existing fixture to verify (--verify)')
    ap.add_argument('--build', action='store_true')
    ap.add_argument('--verify', action='store_true')
    a = ap.parse_args(argv)
    if a.build:
        dest, inv = build(a.repo, a.evidence, a.out)
        rc = verify(dest, a.evidence, inv)          # THE BASELINE, on the pre-declaration tree
        add_declared(a.repo, dest, inv)             # THEN the additions the court must find present
        return rc
    if a.verify:
        if not a.fixture:
            raise SystemExit('--verify needeth --fixture')
        return verify(a.fixture, a.evidence, load(a.evidence))
    ap.print_help()
    return 2


if __name__ == '__main__':
    sys.exit(main())
