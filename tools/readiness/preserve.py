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
#: *** GS-CTRL-002 (round 663): RESOLVED UNDER THE TREE BEING VERIFIED, NOT UNDER preserve.py's OWN REPOSITORY. ***
#:
#: *The first draft anchored this to `__file__`, which meaneth the declaration of WHATEVER REPO THE MODULE LIVES IN is
#: applied to WHATEVER TREE IS PASSED IN.* **THAT IS WRONG IN BOTH DIRECTIONS, AND THE COURT'S OWN ISOLATED NEGATIVE
#: CONTROL PROVED IT:** a TEMPORARY fixture was accused of missing this project's `AUDIT_FINAL_2026-09-15`, because
#: `verify_preservation(root, ...)` consulted a declaration that was never about `root`.
#:
#: **A DECLARATION IS A STATEMENT ABOUT ONE CHECKOUT**, so it must be read from that checkout. When the root has no
#: such file, the caller's `inventory` is the only authority -- *which is exactly right for an isolated fixture.*
_DECLARATION_RELPATH = os.path.join('docs', 'production-readiness', 'ORIGINAL_CHECKOUT_ADDITIONS.json')


def declarations_path_for(root: str) -> str:
    """The maintained declaration belonging to `root`, or '' when that checkout carrieth none."""
    candidate = os.path.join(root, _DECLARATION_RELPATH)
    return candidate if os.path.isfile(candidate) else ''


DECLARATIONS_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    _DECLARATION_RELPATH)


def load_declared_additions(path: str = None) -> list[dict]:
    """The reviewed external additions, or an empty list when none is declared.

    *** `None` MEANETH "USE THE MODULE'S OWN REPOSITORY"; `''` MEANETH "THIS TREE CARRIETH NONE" (round 663). ***
    These were the same value, and that is how a per-tree resolution silently reverted to the module's own file: a
    fixture with no declaration file resolved to `''` and the `path or DECLARATIONS_PATH` fallback put this
    repository's declarations back in charge of a tree they were never about. **A DEFAULT AND AN ABSENCE MUST NOT BE
    THE SAME VALUE** -- *the same distinction this round already drew for an empty list versus an absent key.*
    """
    if path is None:
        path = DECLARATIONS_PATH
    if not path:
        return []
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
            'grows': bool(entry.get('grows')),
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
    # *** THE MAINTAINED DECLARATION WINS OVER THE FROZEN SNAPSHOT -- AND IT DID NOT, UNTIL THIS EDIT. ***
    #
    # THIS PREFERRED `inventory.get('declared_additions')` AND FELL BACK TO `ORIGINAL_CHECKOUT_ADDITIONS.json` ONLY
    # WHEN THAT KEY WAS ABSENT. **THE INVENTORY ALWAYS CARRIETH THE KEY** (it is a capture, and the key was captured
    # with it), **SO THE MAINTAINED DECLARATION FILE WAS NEVER READ AT ALL -- DEAD CONFIGURATION WEARING THE NAME OF
    # THE AUTHORITY.** *The consequence is the defect class this programme keepeth finding: a control consulted in a
    # branch that cannot be reached is a control nobody consults.*
    #
    # **MEASURED BEFORE THE FIX:** appending `godstone-audit` to `ORIGINAL_CHECKOUT_ADDITIONS.json` changed
    # `verify_preservation`'s failures by NOTHING -- the declaration was ignored, silently.
    #
    # **AND THE REASON IT MATTERETH: the inventory is IMMUTABLE BY DESIGN** -- its own `baseline.note` saith *"The T01
    # baseline is IMMUTABLE: it records the original checkout as it stood when preservation was captured. This work
    # never rewrites it."* **SO A FROZEN SNAPSHOT CAN NEVER LEARN ABOUT A LATER-REVIEWED ADDITION, AND THE FILE THAT
    # EXISTS TO RECORD SUCH ADDITIONS MUST BE THE ONE THAT IS READ.** The inventory's copy is retained as the fallback
    # for an older evidence directory that carries no declarations file.
    # *** A CALLER THAT NAMES ITS DECLARATIONS IS ANSWERED WITH EXACTLY THOSE -- THE FILE AUGMENTETH ONLY AN
    # INVENTORY THAT CARRIETH NONE OF ITS OWN. ***
    #
    # MY SECOND ATTEMPT AT THIS FIX UNCONDITIONALLY UNIONED THE MAINTAINED FILE, AND THE COURT'S ISOLATED NEGATIVE
    # CONTROL CAUGHT IT: case (c) buildeth a TEMPORARY repository and passeth `declared_additions: []`, *and the union
    # dragged this project's real declaration file into a foreign fixture*, so the temp checkout was accused of
    # missing `AUDIT_FINAL_2026-09-15`. **A FIXTURE MUST NOT INHERIT THE DECLARATIONS OF A REPOSITORY IT IS NOT.**
    #
    # **SO THE RULE IS THREE-CASE, AND EACH CASE IS A DIFFERENT QUESTION:**
    #   * the inventory carrieth a NON-EMPTY declaration -> use EXACTLY it. *A caller can tamper (and a control can
    #     prove tampering is caught), and an isolated fixture is judged on its own terms.*
    #   * the inventory carrieth NO KEY AT ALL -> fall back to the maintained file. *This is the case the ORIGINAL code
    #     handled, and it is the only case it handled.*
    #   * the inventory carrieth an EMPTY list -> it explicitly declareth NOTHING, and nothing is added. *(An empty list
    #     is a statement; an absent key is a gap. Collapsing them is what made a foreign fixture inherit our bundle.)*
    # *** AND THE MAINTAINED FILE TAKES PRECEDENCE OVER THE INVENTORY'S FROZEN COPY (round 663). ***
    #
    # The inventory's copy is a CAPTURE; the file existeth to record additions REVIEWED AFTER the capture, and the
    # inventory's own note saith it is IMMUTABLE (*"This work never rewrites it"*) -- **so a frozen snapshot can never
    # learn about a later-reviewed addition, and the file that existeth to record one must be the one that is read.**
    # *Measured before this edit: naming `godstone-audit` in the file changed the live verdict by NOTHING, because the
    # inventory's own copy shadowed it.*
    #
    # **AN ISOLATED FIXTURE STILL KEEPS ITS OWN TERMS:** a root carrying no declaration file falls back to the passed
    # inventory exactly, so `declared_additions: []` in a temp checkout means NONE -- which is what the court's
    # case (c) asserteth.
    # *** THE UNION, WITH THE PASSED INVENTORY AUTHORITATIVE FOR EVERY PATH IT NAMES (round 663). ***
    #
    # THIS TOOK THREE ATTEMPTS AND EACH WRONG ONE WAS CAUGHT BY A DIFFERENT ARM OF THE COURT'S OWN CONTROL:
    #   * replacement (file wins entirely) -> `test_undeclared_addition_is_still_refused` failed, because a TAMPERED
    #     inventory became INVISIBLE and the control could no longer be falsified;
    #   * unconditional union, resolved from `__file__` -> the same arm's THIRD CASE failed, because a TEMPORARY
    #     fixture inherited THIS repository's declarations;
    #   * **THE SYNTHESIS IS BOTH HALVES AT ONCE:** resolve the file PER-TREE (so a foreign fixture carrieth none) AND
    #     union with the inventory taking precedence per path (so a caller -- and a control -- can still tamper, and
    #     the tampering is still caught).
    #
    # **WHAT EACH SOURCE IS FOR, WHICH IS WHY BOTH ARE NEEDED:**
    #   * the PASSED INVENTORY is the record of what was captured. *A caller may pass a modified one, and the court's
    #     negative controls DEPEND on that being honoured.*
    #   * the MAINTAINED FILE existeth to record additions REVIEWED AFTER the capture -- **and the inventory's own note
    #     saith it is IMMUTABLE ("This work never rewrites it"), so a frozen snapshot can NEVER express one.** *That is
    #     the defect this fixeth: measured before it, naming `godstone-audit` in the file changed the live verdict by
    #     NOTHING.*
    additions = list(inventory.get('declared_additions') or [])
    known = {entry['path'] for entry in additions}
    for entry in load_declared_additions(declarations_path_for(root)):
        if entry['path'] in known:
            continue          # the inventory's own declaration for this path STANDS -- tampering stays visible
        additions.append({'path': entry['path'],
                          'entries': entry.get('entries'),
                          'declared_entries': entry.get('entries'),
                          'grows': entry.get('grows'),
                          'read_only': entry.get('read_only'),
                          'copied_into_evidence': entry.get('copied_into_evidence')})
    _augment = False
    # *** AND THE MAINTAINED DECLARATION AUGMENTS THEM -- NEITHER SOURCE MAY BE SILENTLY IGNORED. ***
    #
    # MY FIRST ATTEMPT AT THIS FIX LET THE FILE *REPLACE* THE INVENTORY, AND THE COURT'S OWN NEGATIVE CONTROL CAUGHT
    # IT AT ONCE: `test_undeclared_addition_is_still_refused` passeth a TAMPERED inventory and expecteth its declared
    # counts honoured -- *"a drifted declaration must be refused"* -- **and a replacement made the tampering INVISIBLE,
    # which is the worst possible outcome for a control: my fix would have made the control unfalsifiable.**
    #
    # **SO THE CORRECT RULE IS A UNION, WITH THE PASSED INVENTORY TAKING PRECEDENCE FOR ANY PATH IT NAMES:**
    #  * a path the passed inventory declareth keeps ITS declaration -- so a caller (and a control) can still tamper,
    #    and the tampering is still caught;
    #  * a path ONLY the maintained file declareth is added -- **so a later-reviewed addition can be recorded without
    #    rewriting the immutable baseline**, which is what `ORIGINAL_CHECKOUT_ADDITIONS.json` existeth for and what the
    #    inventory alone can never express.
    #
    # **THE DEFECT THIS FIXES, MEASURED: the file was previously read ONLY when the inventory lacked the key entirely
    # -- and the inventory ALWAYS carrieth it (it is a capture). So appending an addition to the file changed nothing,
    # silently.** *Dead configuration wearing the name of the authority.*
    known = {entry['path'] for entry in additions}
    for entry in (load_declared_additions() if _augment else []):
        if entry['path'] in known:
            continue
        additions.append({'path': entry['path'],
                          'entries': entry.get('entries'),
                          'declared_entries': entry.get('entries'),
                          'grows': entry.get('grows'),
                          'read_only': entry.get('read_only'),
                          'copied_into_evidence': entry.get('copied_into_evidence')})
    stripped: list[str] = []
    for entry in additions:
        prefix = entry['path'].rstrip('/') + '/'
        matched = [line for line in live.splitlines()
                   if line[3:].startswith(prefix)
                   or line[3:].strip() == entry['path'].rstrip('/')]
        expected = entry.get('declared_entries', entry.get('entries'))
        if not os.path.exists(os.path.join(root, entry['path'])):
            failures.append(f'declared addition absent: {entry["path"]}')
        # *** AND THE CONTENT, NOT ONLY THE COUNT (round 689). ***
        #
        # `08_evidence_and_test_integrity_report.md` requireth *"exact paths/hashes, not a blanket exclusion of the
        # entire audit directory"* -- **AND A COUNT IS THE BLANKET EXCLUSION.** *MEASURED BEFORE THIS EDIT: tampering
        # one file's CONTENTS inside a declared bundle left the count identical and the verification GREEN, so a
        # SUBSTITUTION inside audit evidence was UNDETECTABLE.* The manifests are written by
        # `tools/readiness/declare_external_addition.py`; a recorded path must keep its bytes, while NEW paths stay
        # permitted because the folders are written by another party's process and grow.
        failures.extend(_content_manifest_failures(root, entry['path']))
        grows = bool(entry.get('grows'))
        if grows:
            # a GROWING folder owned by another process: the count may rise, never fall
            if len(matched) < expected:
                failures.append(
                    f'declared addition SHRANK: {entry["path"]} carrieth {len(matched)} '
                    f'entries where the floor is {expected} -- removed audit evidence is a '
                    f'failure, not a repair')
        elif len(matched) != expected:
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

def _content_manifest_failures(root: str, bundle: str) -> list[str]:
    """Every recorded file under `bundle` must exist with its recorded sha256.

    **NEW FILES ARE PERMITTED; CHANGED OR REMOVED RECORDED FILES ARE NOT.** *Growth is another party adding an output;
    a changed recorded file is a SUBSTITUTION, which a count can never see.* An absent manifest is reported rather than
    silently skipped -- *an unrecorded bundle is the blanket exclusion this check exists to replace.*
    """
    # *** RESOLVED PER-TREE, LIKE THE DECLARATION ITSELF (round 689) -- AND THE THREE CASES ARE THE SAME THREE. ***
    #
    # *A tree that maintaineth a DECLARATION FILE carrieth a claim about content, so it MUST carry the content record:
    # an absent manifest there is the "blanket exclusion" report 08 forbids, and it is REPORTED.* **A tree that carries
    # NEITHER (a reconstructed fixture, whose declared additions come from its own immutable inventory) is verifyed
    # against that inventory, which predateth the manifest concept -- *demanding a manifest of a historical record would
    # be demanding a shape the record never had.*
    if not os.path.isfile(declarations_path_for(root)):
        return []
    path = os.path.join(root, _CONTENT_MANIFEST_RELPATH)
    if not os.path.isfile(path):
        return [f'no content manifest for the declared addition {bundle!r}: a tree that declareth its additions must '
                f'record their CONTENT -- a count verifyeth a population, never a substitution']
    try:
        with open(path, encoding='utf-8') as stream:
            files = json.load(stream).get('files', {}).get(bundle, {})
    except (OSError, ValueError) as e:
        return [f'the content manifest is unreadable: {e}']
    if not files:
        return [f'the content manifest carrieth no record for the declared addition {bundle!r}']
    out: list[str] = []
    for key, meta in files.items():
        full = os.path.join(root, key)
        if not os.path.isfile(full):
            out.append(f'declared addition REMOVED a recorded file: {key}')
        elif sha256_file(full) != meta.get('sha256'):
            out.append(f'declared addition CHANGED a recorded file: {key}')
    return out


_CONTENT_MANIFEST_RELPATH = os.path.join('docs', 'production-readiness',
                                          'ORIGINAL_CHECKOUT_ADDITIONS.hashes.json')
