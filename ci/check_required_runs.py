#! /usr/bin/env python3
"""THE REQUIRED-RUN MANIFEST -- what the ledger OWES, checked against what it CARRIETH.

WHY THIS EXISTETH. The independent audit (2026-09-18), finding GS-FINAL-001, closed its remediation
spec with a limit it named rather than hid:

    "A required-run manifest must independently forbid wholesale deletion of a required record or
     population."

The digest checker (`ci/check_evidence_digests.py`) verifies THAT WHAT THE RECORD NAMES IS TRUE: every
named log is present and hashes to its recorded digest. It cannot, by construction, notice that a
record was DELETED -- delete a finding's evidence alongside its claim and the digest checker reports a
clean sheet over a smaller population. This instrument closeth exactly that hole, and no other.

WHAT IT ENFORCES, AND WHAT IT DELIBERATELY DOES NOT.

  ENFORCED -- the obligations the ledger's own protocol stateth:
    1. THE POPULATION. The findings population equalleth the audit registry's own count
       (`counts.by_status` sums to `{OPEN: 54}` at the audited snapshot). A finding removed whole --
       the wholesale deletion this instrument existeth to catch -- reddens here.
    2. EVERY FINDING CARRIETH SOMETHING. Each finding must carry at least one run log OR a RED-case
       record. A finding stripped of both is an empty claim.
    3. THE STATUS IS ONE I MAY SET. `VERIFIED_FIXED` belongs to an independent audit alone; if this
       ledger ever carrieth it, that is a finding against this work.
    4. THE DERIVED COUNT AGREES. The summary NAMED BY `counts.by_status_derived_at_round` must
       equal the population actually derived from each finding's own `my_status` field -- so a
       summary cannot drift from the entries it summariseth.

       *** THE SUMMARY IS FOUND BY ITS POINTER, NOT BY A HARD-CODED ROUND (round 608). ***
       THIS CLAUSE PREVIOUSLY READ `counts.by_status_derived_at_round_530` **LITERALLY**, AND A
       HARD-CODED ROUND IS A HISTORICAL RECORD, NOT A SUMMARY: once any status moved past round 530
       the two could ONLY disagree, so the invariant silently stopped tracking and REDDENED on a
       record that was perfectly honest about being old. **MEASURED THIS ROUND: the round-530 block
       read 48/6 while the entries derived 49/5 -- and the block was not wrong, it was STALE.** A
       round-530 record must not be asked to describe a round-608 population. The ledger carrieth
       `by_status_derived_at_round` = 530 (the pointer) and the block named for it, so the check now
       followeth the pointer and comparerh the CURRENT derived summary against the entries. **THIS IS
       THE SAME DEFECT CLASS THE LEDGER FILEth AS `GS-FINAL-012` -- narrative serving as current state
       after the state had moved -- AND IT WAS SITTING INSIDE THE INSTRUMENT THAT HUNTETH IT.**

  RECORDED, NOT ENFORCED, AND THE DISTINCTION IS THE POINT:
    * A RED SAVED AS PROSE RATHER THAN A LOG PATH. Twenty-two findings describe their red in the
      `my_red_case` field as TEXT, with the run itself registered among `my_logs`. This instrument
      REPORTETH that population instead of demanding a shape the ledger never promised.
    * A RED THAT WAS NOT CONSTRUCTIBLE. At least one finding states outright that no pre-repair
      behavioural red could be built for its clauses, and WHY (a compile-time fact on that isle, not a
      difficulty). A manifest that demanded a red for it would be demanding a fabrication. These are
      COUNTED and NAMED as the disclosed class they are.

  NOT ENFORCED EITHER, AND THE REASON IS STATED RATHER THAN PAPERED OVER: this instrument does NOT
  assert a required NUMBER of runs per finding. The ledger recordeth each finding's runs as a list with
  no declared denominator, and inventing one here would be exactly the fabrication this programme
  forbiddeth. A finding whose evidence was PARTIALLY deleted still passes -- that remainder is a real
  and open gap, named in the finding's own `pending_proof` and in the audit's `UNABLE_TO_VERIFY`
  dispositions, and it is not pretendable-away by a manifest.

Usage:
    python3 ci/check_required_runs.py [--ledger PATH] [--json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"

# THE STATUSES THIS WORK MAY SET. `VERIFIED_FIXED` is DELIBERATELY absent: only an independent audit
# may write it, so its presence here is a defect in this work rather than a completion.
STATUSES_I_MAY_SET = {
    "OPEN",
    "RED_WRITTEN",
    "FIX_SUBMITTED",
    "PARTIAL",
    "BLOCKED_EXTERNAL",
    "DEFERRED_DEPENDENCY",
}


def _log_paths(value) -> list:
    """A record's `log` field is a scalar OR a list. Both are shapes the record useth."""
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        return [v.strip() for v in value if isinstance(v, str) and v.strip()]
    return []


def _my_logs_present(value) -> bool:
    """`my_logs` is a LIST OF RECORDS, each carrying its own `log` and digest fields."""
    if not isinstance(value, list):
        return False
    for record in value:
        if isinstance(record, dict) and _log_paths(record.get("log")):
            return True
        if isinstance(record, str) and record.strip():
            return True
    return False


def audit(ledger_path: Path) -> dict:
    state = json.loads(Path(ledger_path).read_text(encoding="utf-8"))
    findings = state.get("findings") or {}
    counts = state.get("counts") or {}

    # 1. THE POPULATION.
    registry_total = sum((counts.get("by_status") or {}).values())
    errors = []

    # 2/3/4. PER-FINDING OBLIGATIONS.
    empty_claims, illegal_status = [], []
    red_as_prose = []
    derived = {}
    for fid, entry in sorted(findings.items()):
        status = entry.get("my_status")
        derived[status] = derived.get(status, 0) + 1
        if status not in STATUSES_I_MAY_SET:
            illegal_status.append((fid, status))
        red = entry.get("my_red_case")
        has_red = bool(red) and (isinstance(red, str) or _log_paths(red.get("log")) if isinstance(red, dict) else True)
        if isinstance(red, str) and red.strip():
            red_as_prose.append(fid)
        if not _my_logs_present(entry.get("my_logs")) and not has_red:
            empty_claims.append(fid)

    if registry_total and len(findings) != registry_total:
        errors.append(
            "the findings population is %d while the audit registry declareth %d -- A FINDING WAS "
            "REMOVED WHOLE, which is the deletion this manifest existeth to catch"
            % (len(findings), registry_total))
    for fid, status in illegal_status:
        errors.append("%s carrieth status %r, which this work may not set (VERIFIED_FIXED belongs to "
                      "an independent audit alone)" % (fid, status))
    for fid in empty_claims:
        errors.append("%s carrieth neither a run log nor a RED case: an empty claim" % fid)

    # 5. THE DERIVED COUNT AGREES WITH ITS OWN ENTRIES. An explicitly-zero status is NOT a
    # disagreement -- the declared block recordeth the zero that `OPEN 0` earned -- so a status is
    # compared where it carrieth a count, and a status the entries do not carry is only a disagreement
    # when the declared count is NONZERO.
    # THE SUMMARY IS FOUND BY ITS POINTER. `by_status_derived_at_round` nameth the round the current
    # summary was derived at, and the block for that round is the one to compare. A block from an
    # OLDER round is a historical record and is NOT compared -- asking a round-530 record to describe
    # a round-608 population is a disagreement that can never be resolved, which is how this clause
    # came to redden on an honest ledger. (The pointer is required: without it, "the current summary"
    # is ambiguous among the many historical blocks the ledger carrieth, and guessing the newest key
    # by suffix would be the same hard-coding one layer up.)
    current_round = counts.get("by_status_derived_at_round")
    summary_key = "by_status_derived_at_round_%s" % current_round if current_round is not None else None
    if summary_key is None:
        errors.append("counts.by_status_derived_at_round is absent, so THIS CONTROL cannot tell the "
                      "current summary from the ledger's historical ones -- and a control that cannot "
                      "identify its subject cannot judge it")
    declared = counts.get(summary_key) or {}
    if summary_key is not None and not declared:
        errors.append("counts.by_status_derived_at_round nameth round %r but %s is absent or empty -- "
                      "the pointer and its block must agree, or the summary is unreachable" %
                      (current_round, summary_key))
    if declared:
        disagreement = {k: (declared.get(k, 0), derived.get(k, 0))
                        for k in set(declared) | set(derived)
                        if declared.get(k, 0) != derived.get(k, 0) and (declared.get(k, 0) or derived.get(k, 0))}
        if disagreement:
            errors.append("%s readeth %s while the entries "
                          "themselves derive %s -- a summary that disagreeth with what it summariseth "
                          "on: %s"
                          % (summary_key, json.dumps(declared, sort_keys=True), json.dumps(derived, sort_keys=True),
                             json.dumps({k: {"declared": d, "derived": v} for k, (d, v) in disagreement.items()},
                                        sort_keys=True)))

    return {
        "ledger": str(ledger_path),
        "population": len(findings),
        "registry_total": registry_total,
        "derived_by_status": derived,
        "declared_by_status": declared,
        "empty_claims": empty_claims,
        "illegal_status": [{"finding": f, "status": s} for f, s in illegal_status],
        "red_recorded_as_prose": red_as_prose,
        "errors": errors,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="the ledger's required-run obligations")
    ap.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    r = audit(Path(args.ledger))
    failed = bool(r["errors"])

    if args.json:
        print(json.dumps(r, indent=1, ensure_ascii=False))
        return 1 if failed else 0

    for message in r["errors"]:
        print("::error::%s" % message)
    print("required runs: %d finding(s) of a declared %d | derived %s"
          % (r["population"], r["registry_total"], json.dumps(r["derived_by_status"], sort_keys=True)))
    print("  RECORDED, NOT ENFORCED: %d finding(s) describe their RED as prose rather than a log path "
          "-- reported because a manifest must not demand a shape the record never promised"
          % len(r["red_recorded_as_prose"]))
    if failed:
        print("required runs: FAILED (%d defect(s)); A CLAIM THAT OUTLIVETH ITS RECORD IS NOT A CLAIM"
              % len(r["errors"]))
        return 1
    print("required runs: PASSED (every required record and population is present, and the counts "
          "derive from the entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
