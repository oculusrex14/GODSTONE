"""Re-derive current_assessment from the entries. Run after ANY status change.

THE CONTROL CAUGHT ITS OWN AUTHOR'S DRIFT THE FIRST TIME IT WAS USED: setting GS-FINAL-012 to FIX_SUBMITTED left
`derived_status_counts.audit_13_new` reading 6 while the entries derived 7, and `ci/check_current_assessment.py`
REFUSED the ledger. THAT IS THE CONTROL WORKING, and the remedy is not to hand-edit the count -- it is to make the
block derive itself, which is what this script is.
"""
import hashlib, json, subprocess
from pathlib import Path
from collections import Counter

ROOT = Path('/Users/oculus/Projects/GODSTONE')
L = ROOT / 'docs/remediation/REMEDIATION_STATE.json'
d = json.loads(L.read_text(encoding='utf-8'))
ca = d['current_assessment']

findings = d['findings']
new = d['independent_audit_new_findings']['findings']
closure = json.loads((ROOT / 'godstone-audit/data/closure_matrix.json').read_text(encoding='utf-8'))

ca['candidate_sha'] = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT,
                                     capture_output=True, text=True).stdout.strip()
ca['derived_status_counts']['original_54'] = dict(Counter(v.get('my_status') for v in findings.values()))
ca['derived_status_counts']['audit_13_new'] = dict(Counter(v.get('my_status') for v in new.values()))
# *** ROUND 608: THE DERIVED SUMMARY THAT NOBODY DERIVED. ***
#
# `ci/check_required_runs.py` requireth that the summary named by `counts.by_status_derived_at_round` equalleth the
# population derived from the entries -- AND THIS SCRIPT DID NOT WRITE IT, so the block was hand-maintained and DRIFTED
# (measured: it read 48/6 at round 530 while the entries derived 49/5, and the control REDDENED on it). **A SUMMARY THAT
# IS TYPED BY HAND IS A SUMMARY THAT WILL LIE**, which is the same lesson this file's own docstring recordeth from the
# first time the current-assessment control caught its author. The block is DERIVED HERE, at the round the pointer
# names, so no status change can move the entries without moving the summary.
_counts = d['counts']
_round = _counts.get('by_status_derived_at_round')
if _round is not None:
    _counts['by_status_derived_at_round_%s' % _round] = dict(
        Counter(v.get('my_status') for v in findings.values()))

ca['independent_audit_dispositions_at_e07e6ca'] = dict(
    Counter(r['status'] for r in closure if r.get('record_type') == 'original_finding'))

# re-derive the two remaining lists from the entries' own pending_proof
internal, external = [], []
EXTERNAL = ('device', 'native_models', 'llamacpp', 'llama_cpp', 'sqlcipher', 'acquisition', 'signing',
            'approved content', 'xcui', 'androidtest', 'physical', 'radio', 'external gate', 'instrumentation',
            'artifact', '10,000', 'guard mutant', 'ui-testing', 'context-bearing')
for source in (findings, new):
    for fid, v in sorted(source.items()):
        if v.get('my_status') in ('FIX_SUBMITTED', 'VERIFIED_FIXED'):
            continue
        for item in (v.get('pending_proof') or []):
            low = item.lower()
            (external if any(m in low for m in EXTERNAL) else internal).append(f'{fid}: {item[:180]}')
ca['internal_remaining'] = internal
ca['external_acceptance'] = external

L.write_text(json.dumps(d, indent=1, ensure_ascii=False), encoding='utf-8')
print('candidate:', ca['candidate_sha'][:8])
print('original_54:', ca['derived_status_counts']['original_54'])
print('audit_13_new:', ca['derived_status_counts']['audit_13_new'])
print('internal_remaining:', len(internal), '| external_acceptance:', len(external))
