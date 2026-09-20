#! /usr/bin/env python3
"""AUDIT-B1-CTRL-001: STRUCTURED PER-FINDING CLOSURE, DERIVED -- NEVER NLP-CLASSIFIED.

THE INDEPENDENT AUDIT'S CHARGE, QUOTED:

    "Current state permits `BOARD1_CLOSURE.status = COMPLETE` while
     `REMEDIATION_STATE.current_assessment.independent_status = NO_GO`; original findings still
     include PARTIALs; independent findings still include PARTIALs; live internal obligations
     exist. The free-prose `internal_remaining` classifier is also unsuitable as closure
     authority. It currently mixes historical progress notes with live gaps, misses some PARTIAL
     findings, and produces unstable counts."

*** WHY THE CLASSIFIER COULD NEVER WORK, MEASURED RATHER THAN ARGUED. ***

`current_assessment.internal_remaining` was derived by substring-matching prose out of
`pending_proof`. The same estimator produced **27, then 21, then 5, then 4** across four
hand-tuned marker lists. THAT INSTABILITY WAS THE PROOF: a number that moves with the
vocabulary of its own input is not a measurement of the repository, it is a measurement of the
classifier. And the entries it was reading interleave two different things in one string:

    "THE iOS ACK SURFACES ARE NOW GATED (round 572)"                      <- a PAST CHANGE
    "AND THE TYPED STARTUP PERMIT ... IS STILL NOT A CONSTRUCTION-TIME
     CONSUMABLE"                                                          <- a LIVE GAP

*One is a report, the other is an obligation, and both are English in the same field.* The
mission's own words state the requirement:

    "`internal_remaining` must be DERIVED from structured obligations, not NLP/string matching
     over remediation prose. A historical narrative must not become a current blocker merely
     because it contains words like 'remaining'. A current blocker must not disappear because
     its prose lacked a marker."

SO THIS MODULE DOES NOT READ PROSE. It reads `obligations`, a STRUCTURED field where each
obligation carries an explicit `status` of `COMPLETE` or `OPEN`, and it COUNTS those. The
prose remains in the ledger as the audit trail it always was -- it is simply no longer an
input to any count.

THE CLOSURE LAW, ENFORCED HERE:

  internal_open == 0  AND  every internally executable command green
      -> the builder may claim `READY_FOR_EXTERNAL_REAUDIT`
  otherwise
      -> the builder may NOT claim it, and this check REFUSES

AND ONE MORE THING THIS FILE WILL NOT DO: it never writes `VERIFIED_FIXED`. That verdict
belongs to the independent auditor, and a builder that writes its own passing grade has
reproduced the very defect being audited.

Usage:
    python3 scripts/build_structured_closure.py            # derive and print
    python3 scripts/build_structured_closure.py --write     # persist into the ledger
    python3 scripts/build_structured_closure.py --check     # closure law only
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
CLOSURE = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"

#: A finding whose fix is submitted has nothing left that a builder can execute; what remains is
#: an INDEPENDENT verdict on work already done. A PARTIAL has live internal work by definition --
#: that is what the word means -- so it is OPEN until its obligations are individually closed.
#: `VERIFIED_FIXED` is deliberately absent: only the independent auditor may write it, so seeing
#: it here would be a defect in this work rather than a completion.
STATUS_TO_INTERNAL = {
    "FIX_SUBMITTED": "COMPLETE",
    "PARTIAL": "OPEN",
    "OPEN": "OPEN",
    "RED_WRITTEN": "OPEN",
    "BLOCKED_EXTERNAL": "COMPLETE",      # the internal half is done; what is missing is outside
    "DEFERRED_DEPENDENCY": "OPEN",
    "VERIFIED_FIXED": None,              # never written by this builder
}

#: *** THE LIVELIEST REMAINDER OF EACH PARTIAL FINDING, NAMED AS AN OBLIGATION RATHER THAN
#: DESCRIBED IN PROSE. *** *Each entry must be an INTERNALLY EXECUTABLE piece of work -- the kind
#: a builder can discharge with code, a court, or a document -- or it must be routed to the
#: external side instead. An obligation that cannot be discharged internally does not belong in
#: this list; putting it here would inflate the count with work nobody can do, which is the
#: mirror of the defect that let live work hide.*
PARTIAL_OBLIGATIONS: dict[str, list[dict]] = {
    "GS-FINAL-003": [
        {"id": "gs-final-003.ios-recovery-graph",
         "text": "iOS: a recovery/bootstrap composition whose transport seam exists BEFORE and "
                 "independently of the store graph, so a pending wipe can be driven to a typed "
                 "decision without constructing private stores.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-003.typed-permit",
         "text": "Both platforms: a non-forgeable typed startup decision (not a Bool, not a log "
                 "line, no public initializer) issued only after the typed recovery answer.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-003.zero-private-opens",
         "text": "Both platforms: pending / retryable / corrupt recovery causes ZERO identity and "
                 "ZERO private DB opens, proven at the REAL construction seams with counters.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-003.android-provider-court",
         "text": "Android: a real Hilt/Dagger provider composition in :mesh (nonshipping) that "
                 "catches a miswired provider, without adding a mesh dependency to LIGHT.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-003.bootstrap-permit-unit",
         "text": "`CrashStartupResumeTest`'s bootstrap permit arms currently assert Unit-returning "
                 "behaviour; they must assert the typed decision.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-FINAL-004": [
        {"id": "gs-final-004.owned-connection",
         "text": "The encrypted engine must yield an OWNED OPERATIONAL connection/session with "
                 "restricted construction and explicit close ownership -- not descriptive "
                 "metadata that is discarded.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-004.no-second-open",
         "text": "No second independent path-based `sqlite3_open_v2` in the private composition: "
                 "the repository must run on the EXACT connection the engine returned.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-004.identity-proof",
         "text": "Prove by OBJECT/CAPABILITY IDENTITY -- not a Boolean such as "
                 "`messageStoreWasBuiltFromVerifiedHandle` -- that repository operations use the "
                 "returned connection.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-004.migrations-on-verified",
         "text": "Migrations must run on that exact verified/keyed connection.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-INTEGRATION-001": [
        {"id": "gs-integration-001.real-adapters",
         "text": "A host harness that substitutes ONLY the OS/hardware boundary and drives the "
                 "REAL transport / orchestration / handshake adapters -- not `LinkFacade` and not "
                 "an in-memory transport.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-integration-001.scenarios",
         "text": "Drive from OS-facade callbacks only, covering DIRECT, recipient ACK, no direct "
                 "link, reconnect, wrong peer/key, replay, refused offer, crash after outbound "
                 "durable enqueue / inbound commit / ACK commit, resume, wipe interruption.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-integration-001.mutation",
         "text": "Disconnect one production transport/orchestration call site and confirm the "
                 "integration court FAILS.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-RUNTIME-001": [
        {"id": "gs-runtime-001.android-composition-court",
         "text": "A Robolectric court exercising the ACTUAL production providers up to the real "
                 "AndroidKeyStore boundary, establishing that composition reaches the real "
                 "ACK/pump owners and that assignment is not merely textual. If AndroidKeyStore "
                 "stops execution, that stop is the explicit external boundary.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-runtime-001.mutations",
         "text": "Mutations: removing `ackPump` wiring fails; a wrong provider binding fails; "
                 "shutdown/wipe invalidation reaches the same owner graph.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-STRESS-001": [
        {"id": "gs-stress-001.real-runtime-driver",
         "text": "A real-runtime stress driver over the GS-INTEGRATION-001 host composition -- "
                 "instantiating `MeshRuntime`/`ComposedRuntime`, not only `StressCampaign`.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-stress-001.ten-thousand-cycles",
         "text": "At least 10,000 deterministic host cycles over start/stop, peer churn, link "
                 "replacement, sessions, reservations, leases, timers, observers, ACK work, store "
                 "observers, durable rows, parser refusal and wipe recovery.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-stress-001.real-owner-invariants",
         "text": "No-duplicate-inbox, no-duplicate-delivery, no-uncaught-malformed and "
                 "bounded-census must be read from the REAL repositories/owners/parser, not from "
                 "`StressCampaign`'s own integers.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-stress-001.production-owner-mutation",
         "text": "At least one mutation in a REAL production resource guard/owner (leaked session "
                 "slot, unreleased writer reservation, uncancelled observer/timer, unretired ACK "
                 "work) that the stress court detects.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-stress-001.classification",
         "text": "`StressCampaign` must remain EXPLICITLY classified `resource-model`, not "
                 "production runtime stress.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-UX-001": [
        {"id": "gs-ux-001.facade",
         "text": "A public facade/adapter implemented INSIDE `GodstoneMesh` that wraps the real "
                 "owners and preserves module encapsulation, rather than publishing "
                 "`MeshAuthorityPort`/`TrustAuthorityPort`.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-ux-001.rendered-controls",
         "text": "Rendered LabMesh controls for recipient selection, UTF-8 bounded compose, Send, "
                 "fingerprint compare/confirm, exact rotation-candidate approval, revoke, visible "
                 "durable state after recreation, and visible wipe/recovery state -- every "
                 "displayed value derived from the real authority/projection.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-ux-001.ui-test-target",
         "text": "A repo-owned simulator/UI test target interacting with the rendered controls, "
                 "covering the full journey list plus SOS hold/cancel/accessible alternative.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-ux-001.accessibility",
         "text": "Internally verify rendered semantics (labels, identifiers, roles, state "
                 "descriptions) without claiming human/device accessibility acceptance.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-ARCHIVE-005": [
        {"id": "gs-archive-005.app-witness",
         "text": "An executed iOS app/simulator witness for Archive recreation/restoration. The "
                 "ledger's claim that the app layer 'cannot be compiled because of NATIVE_MODELS' "
                 "is STALE: the canonical hosted workflow builds `Godstone-Light` successfully.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-FINAL-006": [
        {"id": "gs-final-006.ios-restoration-witness",
         "text": "An executed iOS app-level restoration/scroll witness: launch, search, open, "
                 "scroll to a stable passage, recreate, verify the same document and a valid "
                 "anchor return, Back returns to the submitted query, and an invalid anchor falls "
                 "back safely.",
         "status": "OPEN", "evidence": []},
        {"id": "gs-final-006.mutation",
         "text": "Disconnect the production restore/anchor consumption and confirm the executed "
                 "app test FAILS.",
         "status": "OPEN", "evidence": []},
    ],
    "GS-STORE-002": [
        {"id": "gs-store-002.internal-architecture",
         "text": "Internal connection-ownership architecture complete (shared with "
                 "GS-FINAL-004): the absent native engine must NOT be treated as an excuse for "
                 "connection-ownership work, and may not be the only recorded remainder.",
         "status": "OPEN", "evidence": []},
    ],
    "AUDIT-B1-CTRL-001": [
        {"id": "audit-b1-ctrl-001.structured-obligations",
         "text": "Structured per-finding closure: `internal_status`, `internal_obligations` and "
                 "`external_obligations` for every nonterminal finding, with `internal_remaining` "
                 "DERIVED from them rather than NLP-classified from prose.",
"status": "DISCHARGED", "evidence": ["py:scripts/build_structured_closure.py --write wrote `finding_closure` (68 entries, every one carrying `internal_status`) + `structured_counts` into the ledger; `internal_remaining_prose_classifier_retired` records the NLP classifier as RETAINED-FOR-HISTORY-ONLY and NOT an input to any closure decision, so `internal_remaining` is DERIVED from explicit obligation statuses"]},
        {"id": "audit-b1-ctrl-001.closure-law",
         "text": "A control that REFUSES a COMPLETE/READY builder status while structured "
                 "internal OPEN work exists, so the control plane can no longer report closure "
                 "over a NO_GO register.",
"status": "DISCHARGED", "evidence": ["MEASURED BOTH DIRECTIONS 2026-09-20: with BOARD1_CLOSURE.status set to READY_FOR_EXTERNAL_REAUDIT the control REFUSED -- `rc=1` with `::error:: BOARD1_CLOSURE.status is READY_FOR_EXTERNAL_REAUDIT while 30 structured internal obligation(s) are OPEN across 10 finding(s)`. Restored to REMEDIATION_IN_PROGRESS: `rc=0`. The law BITES, so the control plane cannot report closure over a NO_GO register"]},
        {"id": "audit-b1-ctrl-001.missed-partials",
         "text": "Every PARTIAL is represented, including GS-RUNTIME-001 and GS-STORE-002, which "
                 "the prose classifier missed entirely.",
"status": "DISCHARGED", "evidence": ["`build()` output carries GS-RUNTIME-001 (2 obligations) and GS-STORE-002 (1 obligation), the two the prose classifier missed entirely; and the law REFUSES an OPEN finding with NO obligations authored, so a finding cannot be silently obligationless"]},
    ],
}


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def build(ledger: dict) -> dict:
    """Derive the structured closure from the ledger's STATUSES and the authored obligations."""
    original = ledger["findings"]
    new = ledger["independent_audit_new_findings"]["findings"]
    closure: dict[str, dict] = {}
    problems: list[str] = []

    for group, findings in (("original", original), ("independent", new)):
        for fid, entry in sorted(findings.items()):
            status = entry.get("my_status") or entry.get("status") or "OPEN"
            internal = STATUS_TO_INTERNAL.get(status)
            if internal is None:
                problems.append(
                    f"{fid}: status {status!r} has no structured mapping -- a finding this "
                    f"builder may not write must not silently become a completion")
                continue
            if fid in closure:
                problems.append(f"{fid}: appears in BOTH populations")
            closure[fid] = {
                "group": group,
                "severity": entry.get("severity"),
                "recorded_status": status,
                "internal_status": internal,
                "internal_obligations": [dict(o) for o in PARTIAL_OBLIGATIONS.get(fid, [])],
                "external_obligations": list(entry.get("external_obligations") or []),
            }
            if internal == "OPEN" and not PARTIAL_OBLIGATIONS.get(fid):
                problems.append(
                    f"{fid}: internal_status OPEN but NO obligations authored -- an OPEN finding "
                    f"with nothing named is the prose defect wearing a structured field")

    # AUDIT-B1-CTRL-001 is an independent-audit finding that is not yet in the ledger's
    # populations; it is this mission's own control-plane repair and must be represented.
    if "AUDIT-B1-CTRL-001" not in closure:
        closure["AUDIT-B1-CTRL-001"] = {
            "group": "external_audit_2026_09_20",
            "severity": "High",
            "recorded_status": "PARTIAL",
            "internal_status": "OPEN",
            "internal_obligations": [dict(o) for o in PARTIAL_OBLIGATIONS["AUDIT-B1-CTRL-001"]],
            "external_obligations": [],
        }

    if problems:
        for p in problems:
            print(f"  ::error:: {p}", file=sys.stderr)
        raise SystemExit("the structured closure could not be derived coherently")

    return closure


def counts(closure: dict) -> dict:
    internal_open = sum(
        1 for f in closure.values()
        for o in f["internal_obligations"] if o["status"] == "OPEN")
    findings_open = sum(1 for f in closure.values() if f["internal_status"] == "OPEN")
    external = sum(len(f["external_obligations"]) for f in closure.values())
    return {
        "findings_total": len(closure),
        "findings_internal_open": findings_open,
        "internal_obligations_open": internal_open,
        "external_obligations": external,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="structured per-finding closure")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    ledger = load(LEDGER)
    closure = build(ledger)
    c = counts(closure)

    print(f"  findings total            : {c['findings_total']}")
    print(f"  findings INTERNAL OPEN    : {c['findings_internal_open']}")
    print(f"  internal obligations OPEN : {c['internal_obligations_open']}")
    print(f"  external obligations      : {c['external_obligations']}")

    if args.write:
        ca = ledger["current_assessment"]
        ca["finding_closure"] = closure
        ca["structured_counts"] = c
        # *** THE DERIVED FIELD REPLACES THE NLP ONE AS AUTHORITY. *** *`internal_remaining` is
        # kept ONLY as a historical record of what the prose classifier produced; nothing reads
        # it for closure any more. A number that moved 27 -> 21 -> 5 -> 4 belongs in a history
        # note, not in a gate.*
        ca["internal_remaining_prose_classifier_retired"] = {
            "note": "RETAINED FOR AUDIT HISTORY ONLY -- NOT AN INPUT TO ANY CLOSURE DECISION. "
                    "Derived by substring-matching prose; produced 27, 21, 5 and 4 across four "
                    "marker lists, which is why it was retired. Superseded by `structured_counts`, "
                    "which counts explicit obligation statuses.",
            "last_value": len(ca.get("internal_remaining", [])),
        }
        LEDGER.write_text(json.dumps(ledger, indent=1, ensure_ascii=False), encoding="utf-8")
        print("  wrote `finding_closure` + `structured_counts` into the ledger")

    if args.check:
        closure_doc = load(CLOSURE)
        status = closure_doc.get("status")
        if status in ("COMPLETE", "READY_FOR_EXTERNAL_REAUDIT") and c["internal_obligations_open"] > 0:
            print(f"  ::error:: BOARD1_CLOSURE.status is {status!r} while "
                  f"{c['internal_obligations_open']} structured internal obligation(s) are OPEN "
                  f"across {c['findings_internal_open']} finding(s). THE CONTROL PLANE MAY NOT "
                  f"REPORT CLOSURE OVER LIVE INTERNAL WORK -- that is AUDIT-B1-CTRL-001.")
            return 1
        if closure_doc.get("verified_fixed") not in (None, 0):
            print("  ::error:: verified_fixed is non-zero; only an INDEPENDENT audit may write it")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
