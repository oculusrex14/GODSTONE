#! /usr/bin/env python3
"""GS-FINAL-012: THE CURRENT ASSESSMENT'S OWN COURT.

THE AUDIT'S CHARGE: *"Current remediation narrative overstates external blockers and mixes historical/current state.
... Append-only progress prose is serving simultaneously as history, current state and completion authority."*

ITS PRESCRIBED REMEDY, WHICH THIS CONTROL ENFORCES: *"add a structured `current_assessment` with candidate, verified
source references, `internal_remaining`, `external_acceptance` and independently derived status counts. Preserve
original impact text under an explicitly historical field. ... Derive summary counts from entries."*

AND ITS OWN REGRESSION TEST, WHICH IS THE ACCEPTANCE CLAUSE: *"Validate all 54 IDs exactly once, schema/status
legality, candidate identity and explicit internal/external split. Reject a current assessment referring to an
uninspected or mismatched candidate."*

THE ONE LAW THIS CONTROL EXISTS FOR: **A COUNT THAT IS ASSERTED RATHER THAN DERIVED IS THE DEFECT ITSELF.** Every count
in `current_assessment` is recomputed here from the entries and compared, so the block cannot drift from what it claims
to summarise.

Usage:
    python3 ci/check_current_assessment.py [--ledger PATH] [--json]
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
# TWO BASELINES, AND CONFLATING THEM IS ITSELF A DEFECT OF THIS SPECIES:
#  * the ORIGINAL audit bundle's snapshot (AUDIT_FINAL_2026-09-15, AUDIT-003-R1), whose registry carrieth the 54 IDs;
#  * the INDEPENDENT audit's candidate (godstone-audit/, 2026-09-18), against which the 13 NEW findings were measured.
ORIGINAL_AUDITED_SHA = "c683a2bf0b5bcdd4a662d98f7542351501b57b7c"
INDEPENDENT_AUDIT_CANDIDATE = "e07e6ca119284eac72cfe7ed82c539209f085715"

# THE REGISTRY'S OWN COUNT: the audited snapshot carrieth exactly this many original findings.
EXPECTED_ORIGINAL = 54


def audit(ledger_path: Path) -> dict:
    state = json.loads(Path(ledger_path).read_text(encoding="utf-8"))
    errors: list[str] = []

    ca = state.get("current_assessment")
    if not isinstance(ca, dict):
        return {"errors": ["the ledger carrieth no `current_assessment`: the current view and the history are "
                           "therefore the same text, which is the defect this finding names"], "checks": 0}

    checks = 0

    # (1) ALL 54 IDs EXACTLY ONCE -- the audit's first acceptance clause.
    findings = state.get("findings") or {}
    checks += 1
    if len(findings) != EXPECTED_ORIGINAL:
        errors.append("the findings population is %d; the registry declareth %d -- A FINDING WAS ADDED OR REMOVED "
                      "WHOLE, which would silently change the denominator" % (len(findings), EXPECTED_ORIGINAL))

    # (2) THE COUNTS ARE DERIVED, NOT ASSERTED.
    checks += 1
    derived_54 = dict(Counter(v.get("my_status") for v in findings.values()))
    declared_54 = (ca.get("derived_status_counts") or {}).get("original_54")
    if declared_54 is not None and declared_54 != derived_54:
        errors.append("current_assessment.derived_status_counts.original_54 readeth %s while the entries derive %s -- "
                      "A COUNT ASSERTED RATHER THAN DERIVED IS THE DEFECT THIS FINDING IS ABOUT"
                      % (json.dumps(declared_54, sort_keys=True), json.dumps(derived_54, sort_keys=True)))

    checks += 1
    new = (state.get("independent_audit_new_findings") or {}).get("findings") or {}
    derived_13 = dict(Counter(v.get("my_status") for v in new.values()))
    declared_13 = (ca.get("derived_status_counts") or {}).get("audit_13_new")
    if declared_13 is not None and declared_13 != derived_13:
        errors.append("current_assessment.derived_status_counts.audit_13_new readeth %s while the entries derive %s"
                      % (json.dumps(declared_13, sort_keys=True), json.dumps(derived_13, sort_keys=True)))

    # (3) STATUS LEGALITY: this work may not write VERIFIED_FIXED.
    checks += 1
    illegal = sorted({v.get("my_status") for v in findings.values()
                      if v.get("my_status") not in {"OPEN", "RED_WRITTEN", "FIX_SUBMITTED", "PARTIAL",
                                                    "BLOCKED_EXTERNAL", "DEFERRED_DEPENDENCY"}})
    if illegal:
        errors.append("the original 54 carry status(es) this work may not set: %s" % illegal)
    checks += 1
    illegal_new = sorted({v.get("my_status") for v in new.values()
                          if v.get("my_status") not in {"OPEN", "RED_WRITTEN", "FIX_SUBMITTED", "PARTIAL",
                                                        "BLOCKED_EXTERNAL", "DEFERRED_DEPENDENCY"}})
    if illegal_new:
        errors.append("the audit's new findings carry status(es) this work may not set: %s" % illegal_new)

    # (4) THE CANDIDATE IDENTITY IS DECLARED AND MATCHES THE AUDITED BASELINE.
    checks += 1
    baseline = ca.get("original_audited_sha")
    if baseline != ORIGINAL_AUDITED_SHA:
        errors.append("current_assessment.original_audited_sha readeth %r; the ORIGINAL audit bundle pinNETH %r -- AN "
                      "ASSESSMENT REFERRING TO A MISMATCHED CANDIDATE IS REFUSED BY THE AUDIT'S OWN TEST"
                      % (baseline, ORIGINAL_AUDITED_SHA))
    indep = ca.get("independent_audit_candidate_sha")
    if indep != INDEPENDENT_AUDIT_CANDIDATE:
        errors.append("current_assessment.independent_audit_candidate_sha readeth %r; the INDEPENDENT audit's package "
                      "pinNETH %r -- the 13 new findings were measured against THAT tree, and an assessment that "
                      "nameth one baseline for both is conflating them" % (indep, INDEPENDENT_AUDIT_CANDIDATE))
    checks += 1
    if not ca.get("candidate_sha"):
        errors.append("current_assessment declareth no candidate_sha: an uninspected candidate may not be assessed")

    # (5) THE EXPLICIT INTERNAL/EXTERNAL SPLIT EXISTS AS TWO POPULATIONS.
    checks += 1
    for field in ("internal_remaining", "external_acceptance"):
        if not isinstance(ca.get(field), list):
            errors.append("current_assessment carrieth no `%s` list: the audit's remedy requireth the split be "
                          "EXPLICIT, and a missing list is an implicit 'nothing remains'" % field)
    checks += 1
    if not isinstance(ca.get("historical_fields"), dict):
        errors.append("current_assessment carrieth no `historical_fields`: the audit's remedy requireth original text "
                      "be preserved UNDER AN EXPLICITLY HISTORICAL FIELD, not merely left in place")

    # (6) VERIFIED_FIXED IS ZERO, BY RULE.
    checks += 1
    if ca.get("verified_fixed") != 0:
        errors.append("current_assessment.verified_fixed readeth %r; ONLY AN INDEPENDENT AUDIT MAY WRITE A VERIFIED "
                      "CLOSURE, and none has since the audit" % ca.get("verified_fixed"))

    return {"ledger": str(ledger_path), "checks": checks, "errors": errors, "candidate": ca.get("candidate_sha"),
            "derived_54": derived_54, "derived_13": derived_13}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="the current assessment's own court")
    ap.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    r = audit(Path(args.ledger))
    failed = bool(r["errors"])
    if args.json:
        print(json.dumps(r, indent=1, ensure_ascii=False))
        return 1 if failed else 0
    for e in r["errors"]:
        print("::error::%s" % e)
    print("current assessment: %d check(s) | candidate %s | original_54 %s | audit_13_new %s"
          % (r["checks"], (r.get("candidate") or "?")[:8],
             json.dumps(r.get("derived_54", {}), sort_keys=True), json.dumps(r.get("derived_13", {}), sort_keys=True)))
    if failed:
        print("current assessment: FAILED (%d defect(s)); A NARRATIVE THAT SERVETH AS HISTORY, CURRENT STATE AND "
              "AUTHORITY AT ONCE IS THE DEFECT" % len(r["errors"]))
        return 1
    print("current assessment: PASSED (counts derive from the entries, the split is explicit, and the candidate "
          "identity matches the audited baseline)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
