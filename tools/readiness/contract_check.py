#! /usr/bin/env python3
"""Contract validators for the T03 normalized contract set.

validate_invariants checks ARCHITECTURE_INVARIANTS.json: schema, frozen
constants, exact-SHA authority links, and the frozen election wording.
validate_profiles checks CAPABILITY_PROFILES.json: shipping exclusions,
readiness constants, and recorded limitations.

Both return a list of human-readable problems; an empty list means valid.
Mutating copies of these documents (platform election, disabled feature
marked available, readiness flipped, approval language dropped) must produce
problems - the T03 suite asserts exactly that.
"""
from __future__ import annotations

import os
import subprocess

import run

ACCEPTED_PROPOSED = ('ACCEPTED', 'PROPOSED', 'SUPERSEDED')
FROZEN_ELECTION_MARKERS = ('unsigned-lexicographic', 'fails closed')
FORBIDDEN_ELECTION = 'platform-based'
PROFILE_KEYS = ('shipping', 'archive', 'mesh', 'oracle', 'sos', 'bulk')
DISABLED_FEATURES = ('mesh', 'oracle', 'sos', 'bulk')


def _blob_sha1(repo_root, path):
    proc = subprocess.run(['git', 'hash-object', path], cwd=repo_root,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def _blob_at_commit(repo_root, commit, path):
    """The blob a path carrieth AT A COMMIT -- the baseline's proof in history."""
    proc = subprocess.run(['git', 'rev-parse', f'{commit}:{path}'], cwd=repo_root,
                          capture_output=True, text=True)
    return proc.stdout.strip() if proc.returncode == 0 else None


FREEZE_MODES = ('normative', 'baseline')


def validate_invariants(repo_root, path):
    """Return problems; empty means the invariants document is valid."""
    problems = []
    doc = run.load_json_strict(path)
    if doc.get('schema_version') != 1:
        problems.append('invariants: schema_version must be 1')
        return problems
    readiness = doc.get('readiness') or {}
    if readiness.get('android_LINK_LAYER_READY') is not False:
        problems.append('invariants: android_LINK_LAYER_READY must be false')
    if readiness.get('ios_linkLayerReady') is not False:
        problems.append('invariants: ios_linkLayerReady must be false')
    link = doc.get('link_info') or {}
    if link.get('bytes') != 13:
        problems.append('invariants: link_info must stay 13 bytes')
    if str(link.get('protocol_version')) not in ('2', '0x02'):
        problems.append('invariants: link_info protocol byte must stay 0x02')
    election = str(link.get('election') or '')
    for marker in FROZEN_ELECTION_MARKERS:
        if marker not in election:
            problems.append(
                f'invariants: frozen election wording lost ({marker!r} missing)')
    if FORBIDDEN_ELECTION in election:
        problems.append(
            'invariants: platform-based election is rejected; the frozen '
            'contract is unsigned-lexicographic with equal failing closed')
    if doc.get('shipping_profile') != 'LIGHT_ARCHIVE_ONLY':
        problems.append('invariants: shipping profile must stay LIGHT_ARCHIVE_ONLY')
    noise = doc.get('noise') or {}
    if 'BLAKE2s' not in str(noise.get('suite') or ''):
        problems.append(
            'invariants: accepted cipher suite must stay BLAKE2s; the SHA-256 '
            'variant is a PROPOSED amendment pending A06, never silent')
    entries = doc.get('entries') or []
    if not entries:
        problems.append('invariants: no entries recorded')
    seen = set()
    for entry in entries:
        entry_id = entry.get('id')
        if not entry_id:
            problems.append('invariants: entry without id')
            continue
        if entry_id in seen:
            problems.append(f'invariants: duplicate entry {entry_id}')
        seen.add(entry_id)
        if entry.get('status') not in ACCEPTED_PROPOSED:
            problems.append(
                f'{entry_id}: status must be one of {ACCEPTED_PROPOSED}')
        if not entry.get('statement'):
            problems.append(f'{entry_id}: missing statement')
        if entry.get('status') == 'PROPOSED' and \
                'not approved' not in entry.get('statement', ''):
            problems.append(
                f'{entry_id}: PROPOSED entries must state they are not '
                f'approved (silent approval is forbidden)')
        for ref in entry.get('authority_paths') or []:
            ref_path = ref.get('path')
            full = os.path.join(repo_root, ref_path or '')
            if not os.path.isfile(full):
                problems.append(f'{entry_id}: authority file missing {ref_path}')
                continue
            # GS-CTRL-002 (the original card's steps 1-2): an authority path is EITHER
            #   normative -- the artifact that DEFINES the contract, which must remain
            #     byte-identical in the working tree; or
            #   baseline  -- an implementation file the blueprint names as a MODIFICATION
            #     TARGET, whose recorded blob must be PROVABLE at its recorded commit
            #     while the current behaviour is exercised by its courts.
            # Freezing implementation bytes in the working tree made a required production
            # edit possible only by re-pinning a hash, and encouraged leaving required
            # implementations as unused helpers.
            freeze = ref.get('freeze')
            if freeze not in FREEZE_MODES:
                problems.append(
                    f'{entry_id}: authority path {ref_path} carrieth no freeze mode '
                    f'({freeze!r}); every authority path must be classified normative or '
                    f'baseline, explicitly')
                continue
            if freeze == 'normative':
                actual = _blob_sha1(repo_root, full)
                if actual != ref.get('blob_sha1'):
                    problems.append(
                        f'{entry_id}: NORMATIVE authority blob drift for {ref_path} '
                        f'(recorded {ref.get("blob_sha1")}, actual {actual}); this artifact '
                        f'DEFINES the contract and must remain byte-identical -- re-record '
                        f'after review, never silently')
                continue
            commit = ref.get('baseline_commit')
            if not commit:
                problems.append(
                    f'{entry_id}: BASELINE authority {ref_path} nameth no baseline_commit, so '
                    f'its recorded blob cannot be proved in history')
                continue
            at_commit = _blob_at_commit(repo_root, commit, ref_path)
            if at_commit is None:
                problems.append(
                    f'{entry_id}: BASELINE authority {ref_path} did not exist at its recorded '
                    f'commit {commit}')
                continue
            if at_commit != ref.get('blob_sha1'):
                problems.append(
                    f'{entry_id}: BASELINE authority blob {ref_path} is NOT what its recorded '
                    f'commit carrieth (recorded {ref.get("blob_sha1")}, at {commit} '
                    f'{at_commit}); a baseline must be a MEASURED fact, never an assertion')
            if not ref.get('current_contract'):
                problems.append(
                    f'{entry_id}: BASELINE authority {ref_path} nameth no current_contract, so '
                    f'the evolving behaviour would be frozen by nothing')
        if entry.get('status') == 'ACCEPTED' and not (
                entry.get('evidence') or {}).get('case_ids'):
            problems.append(
                f'{entry_id}: ACCEPTED entries need at least one evidence case')
    return problems


def validate_profiles(repo_root, path):
    """Return problems; empty means the capability profiles are valid."""
    problems = []
    doc = run.load_json_strict(path)
    if doc.get('schema_version') != 1:
        problems.append('profiles: schema_version must be 1')
    profiles = doc.get('profiles') or {}
    light = profiles.get('LIGHT')
    if light is None:
        problems.append('profiles: LIGHT profile missing')
        return problems
    if light.get('shipping') is not True:
        problems.append('profiles: LIGHT must be the shipping profile')
    if light.get('archive') is not True:
        problems.append('profiles: LIGHT shipping must include Archive')
    for feature in PROFILE_KEYS:
        if feature in ('shipping', 'archive'):
            continue
        if light.get(feature) is not False:
            problems.append(
                f'profiles: LIGHT marks disabled feature {feature!r} '
                f'available; re-enablement needs evidence-backed release '
                f'capability generation (ADR-0002), never a profile edit')
    readiness = light.get('readiness') or {}
    if readiness.get('android') is not False or readiness.get('ios') is not False:
        problems.append(
            'profiles: LIGHT readiness flags must remain false on both '
            'platforms')
    election = doc.get('election') or {}
    rule = str(election.get('rule') or '')
    for marker in FROZEN_ELECTION_MARKERS:
        if marker not in rule:
            problems.append(
                f'profiles: frozen election wording lost ({marker!r} missing)')
    if FORBIDDEN_ELECTION in rule:
        problems.append(
            'profiles: platform-based election is rejected by the frozen '
            'LinkInfo contract')
    authority = doc.get('authority') or {}
    release_doc = authority.get('release_surface')
    if release_doc and not os.path.isfile(os.path.join(repo_root, release_doc)):
        problems.append(f'profiles: release authority missing {release_doc}')
    limitations = ' '.join(doc.get('limitations') or [])
    for marker in ('overflow area', 'HARDWARE gate open', 'BLAKE2s'):
        if marker not in limitations:
            problems.append(
                f'profiles: required limitation text missing ({marker!r})')
    return problems


if globals().get('__name__') == '__main__':
    import sys
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    docs = os.path.join(root, 'docs', 'production-readiness')
    problems = validate_invariants(
        root, os.path.join(docs, 'ARCHITECTURE_INVARIANTS.json'))
    problems += validate_profiles(
        root, os.path.join(docs, 'CAPABILITY_PROFILES.json'))
    for problem in problems:
        print(f'INVALID: {problem}')
    raise SystemExit(1 if problems else 0)