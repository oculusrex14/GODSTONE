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
# *** AND A RULE STATEMENT IS NOT A WORK ITEM (round 667). ***
#
# MEASURED BEFORE THIS EDIT: 14 of the 43 "internal_remaining" entries were not work at all -- they were the sentence
# *"INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED."* **THAT IS A RULE, STATED IN EVERY
# `pending_proof` LIST, AND COUNTING IT AS REMAINING WORK INFLATETH THE ONE NUMBER A READER USES TO JUDGE WHAT IS
# OWED** -- *"43 internal items" reads as 43 pieces of work, and 14 of them are the same sentence fourteen times.*
# *This is the count-vs-meaning defect the programme has filed repeatedly: a tally that is DERIVED but not CLASSIFIED.*
RULE_MARKERS = ('independent verification', 'only an independent audit may mark')
#: Markers of ROUND NARRATIVE -- a past change reported, not an obligation owed or an artifact awaited.
# *** AND `'round '` WAS TOO BLUNT, WHICH THE NEXT MEASUREMENT CAUGHT (round 675): IT MATCHED ANY ITEM THAT NAMED A
# ROUND, INCLUDING ITEMS THAT STATE AN *UNMET* OBLIGATION WHILE CITING THE ROUND THAT MEASURED IT -- *"PHASE 1 EXIT,
# CLAUSE 1 IS UNMET AND RECORDED AS SUCH (round 576)"*, *"WHAT IS STILL OWED IS UNCHANGED AND NAMED"*. **THOSE ARE
# OBLIGATIONS, AND EXCLUDING THEM WOULD HIDE WORK THE LEDGER EXISTS TO REPORT.** *A marker that cannot tell "round 576
# found X done" from "round 576 found X unmet" is the same failure as a name asserting what the mechanism does not
# provide, one layer out.* **THE MARKERS ARE THEREFORE PHRASES THAT STATE COMPLETION, NOT MENTIONS OF A ROUND.***
NARRATIVE_MARKERS = ('is repaired and re-measured', 'is landed', 'was re-measured and found',
                     'now landed', 'is now landed', 'this field was empty',
                     'is now documented', 'is now precise', 'is now stated correctly',
                     'is closed, and the superseded', 'is measured)', 'is proven)')
narrative_all = []
for source in (findings, new):
    for fid, v in sorted(source.items()):
        if v.get('my_status') in ('FIX_SUBMITTED', 'VERIFIED_FIXED'):
            continue
        for item in (v.get('pending_proof') or []):
            low = item.lower()
            if low.strip().startswith(RULE_MARKERS):
                continue          # a RULE, not work -- it carrieth no obligation a builder can discharge
            # *** AND THE SAME CLASSIFICATION APPLIES ON THE EXTERNAL SIDE (round 675, measured). ***
            #
            # MEASURED: 5 of the 23 `external_acceptance` items were ROUND NARRATIVE -- *"STEP 7'S APP-LEVEL ARM NOW
            # EXISTS AND PASSES"*, *"THE WIRED PROVIDER WAS INVERTED ... AND SURVIVED EVERY LANE"*, *"THE CORE'S
            # BLOCKER IS NOW STATED CORRECTLY"* -- **PAST CHANGES FILED UNDER A HEADING THAT REPORTS WHAT AWAITS AN
            # EXTERNAL ARTIFACT.** *A reader judging "what awaits acquisition" was being shown what had already landed.*
            # **AND A FACT RESTATED ONCE PER ROUND INFLATETH THE COUNT THE SAME WAY:** GS-STRESS-001's *"NO DEVICE AND
            # NO RUNTIME STRESS EVIDENCE"* appeared **four times**, each appending repeating the same standing gap.
            #
            # *So the classifier now EXCLUDES narrative from both lists AND DEDUPLICATES by content, reporting each
            # excluded population separately rather than silently dropping it -- a suppression a reader cannot see is
            # itself the defect this round is repairing.*
            # *** TWO OBJECTIVE BUGS IN THIS CLASSIFIER, BOTH FIXED HERE. ***
            #
            # (a) THE SLICE `[4:]` DROPPED THE FOUR MARKERS THIS MODULE'S OWN COMMENT CITES AS
            #     THE PARADIGM TO EXCLUDE. *The dropped four are 'is repaired and re-measured',
            #     'is landed', 'was re-measured and found' and 'now landed' -- i.e. exactly the
            #     two phrases the round-667 note above names as round narrative ("ROUND 545:
            #     CLAUSE (i) IS REPAIRED AND RE-MEASURED", "ROUND 544: STEP 5 IS LANDED"). The
            #     SLICE CONTRADICTED ITS OWN DOCSTRING, and the consequence was measured: entries
            #     describing work already done were filed as work owed.*
            #
            # (b) LITERAL SUBSTRING MATCHING WAS DEFEATED BY MARKDOWN. *These bullets bold their
            #     subjects -- `THIS FIELD WAS **EMPTY**` -- so a marker written 'this field was
            #     empty' could never match the text it describes.* Normalising the markdown
            #     before matching makes the classifier describe the entries it is reading.
            #
            # *** ONLY THESE TWO DEFECTS ARE FIXED HERE, AND THE MEASURED RESULT IS REPORTED. ***
            # *I TRIED TO GO FURTHER -- adding invented "completion" and "standing gap" phrase
            # lists -- AND THE COUNT OSCILLATED 21 -> 5 -> 4 ACROSS THREE HAND-TUNED VARIANTS.
            # THAT INSTABILITY IS THE PROOF THE METHOD IS WRONG: **AN INVENTED LIST OF PHRASES IS
            # ITSELF AN ASSERTED COUNT**, which is the very defect this module's docstring names.
            # The remaining imprecision is therefore RECORDED as a known limit rather than papered
            # over with more rules.*
            normalised = low.replace('*', '').replace('_', ' ')
            if any(m in normalised for m in NARRATIVE_MARKERS):
                narrative_all.append(f'{fid}: {item[:180]}')
                continue
            bucket = external if any(m in low for m in EXTERNAL) else internal
            entry = f'{fid}: {item[:180]}'
            if entry not in bucket:
                bucket.append(entry)
# *** AND A REPORT OF PAST WORK IS NOT WORK OWED EITHER (round 667, measured one layer out). ***
#
# MEASURED AFTER THE RULE FIX: 20 of the 29 remaining "internal" entries were ROUND NARRATIVE -- *"ROUND 545: CLAUSE (i)
# IS REPAIRED AND RE-MEASURED"*, *"ROUND 544: STEP 5 IS LANDED"* -- **A RECORD OF SOMETHING ALREADY DONE, FILED UNDER A
# HEADING THAT A READER USES TO JUDGE WHAT IS STILL OWED.** *So "29 internal items" would have read as 29 pieces of work
# when 20 of them describe completed repairs.*
#
# **THE DISTINCTION IS NOT EDITORIAL: A `pending_proof` LIST HOLDS BOTH KINDS BY DESIGN** -- it is the finding's evidence
# trail, where each round appendeth what it established -- **and only the SUBSET that still nameth an unperformed
# obligation belongeth under `internal_remaining`.** *A tally derived without that classification is a count whose
# meaning the reader must reverse-engineer, which is the defect class this programme has filed repeatedly.*
ca['internal_remaining'] = internal
ca['internal_round_narrative'] = sorted(set(narrative_all))
ca['excluded_round_narrative'] = len(narrative_all)
ca['external_acceptance'] = external
# AND THE RULE'S OWN POPULATION IS REPORTED SEPARATELY, so the suppression above is VISIBLE rather than silent.
ca['independent_verification_rule_stated_by'] = sorted(
    fid for src in (findings, new) for fid, v in src.items()
    if any(str(x).lower().strip().startswith(RULE_MARKERS) for x in (v.get('pending_proof') or [])))

L.write_text(json.dumps(d, indent=1, ensure_ascii=False), encoding='utf-8')
print('candidate:', ca['candidate_sha'][:8])
print('original_54:', ca['derived_status_counts']['original_54'])
print('audit_13_new:', ca['derived_status_counts']['audit_13_new'])
print('internal_remaining:', len(internal), '| external_acceptance:', len(external))
