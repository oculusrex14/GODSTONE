#! /usr/bin/env python3
"""GS-AUDIT §13: RECOMPUTE THE BLOCKED-TASK MATRIX FROM THE LIVE FILESYSTEM.

THE INDEPENDENT AUDIT'S FINDING, QUOTED:

    "T62/T64/T65 Kotlin readiness courts EXIST today, yet the blocked-task matrix still records
     empty `paths_that_exist` and `court_not_authored`. Recompute it. Do not hand-edit one
     representation while leaving another stale."

*** THE ROW CONTRADICTED ITSELF, WHICH IS WHY NOBODY NOTICED. ***

MEASURED on the frozen candidate, before this edit -- T62's row read:

    "declared_regression_paths": [".../ReadinessT62Test.kt"]     <- names the court
    "internal_witnesses":        [".../ReadinessT62Test.kt"]     <- names it AGAIN
    "paths_that_exist":          []                              <- says it is not there
    "unwritten_paths_justified_by": "court_not_authored"         <- says it was never written

**THE SAME ROW NAMED THE COURT TWICE AND DENIED ITS EXISTENCE ONCE.** A reader who trusted
`paths_that_exist` would open the matrix, conclude the court was owed, and either re-author a
court that already exists or excuse the task as external. *A field that disagrees with two of its
own neighbours is not a record, it is a coin flip.*

AND THE STALENESS HAD A CAUSE WORTH NAMING: `court_not_authored` was TRUE WHEN IT WAS WRITTEN --
these courts were authored later, in the rc3/rc4 rounds -- and **nothing recomputed the field
afterwards.** The matrix was a snapshot wearing the name of a state.

SO THIS MODULE MEASURES, IT DOES NOT REMEMBER: every declared path is stat()ed against the live
tree, per platform, and the existence fields are DERIVED from that. Where a task declares both an
Android and an iOS court and only one exists, the two are reported SEPARATELY rather than
collapsed into one verdict -- the audit's own instruction, and the only shape that can express
"Android done, iOS owed".

Usage:
    python3 scripts/recompute_blocked_matrix.py            # report
    python3 scripts/recompute_blocked_matrix.py --write     # persist
"""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MATRIX = ROOT / "docs" / "production-readiness" / "BLOCKED_TASK_CLOSURE_MATRIX.json"

#: A declared path is classified by WHERE it lives, because that is what a reader needs in order
#: to know which lane owes the work. The audit asked for the two platforms to be separable.
PLATFORM_PREFIXES = {
    "android": ("android/",),
    "ios": ("ios/",),
    "python": ("tools/", "ci/", "scripts/"),
}


def platform_of(path: str) -> str:
    for name, prefixes in PLATFORM_PREFIXES.items():
        if path.startswith(prefixes):
            return name
    return "other"


def recompute(row: dict) -> dict:
    """Measure every declared path against the live tree; derive existence PER PLATFORM."""
    declared = [p for p in (row.get("declared_regression_paths") or [])]
    existing, missing = [], []
    for rel in declared:
        (existing if (ROOT / rel).is_file() else missing).append(rel)

    by_platform: dict[str, dict] = {}
    for rel in declared:
        plat = platform_of(rel)
        slot = by_platform.setdefault(plat, {"exists": [], "missing": []})
        key = "exists" if (ROOT / rel).is_file() else "missing"
        slot[key].append(rel)

    row["paths_that_exist"] = existing
    row["paths_missing"] = missing
    row["declared_paths_by_platform"] = by_platform

    # *** THE JUSTIFICATION MUST NAME WHICH PATHS IT IS ABOUT, OR IT LIES BY OMISSION. ***
    # *My first pass cleared `court_not_authored` only when NOTHING was missing -- so a row could
    # still say "court_not_authored" while listing an existing Android court beside a missing iOS
    # one, which is the SAME defect one layer in (a field contradicting its neighbours). MEASURED:
    # five rows read that way. The justification is therefore scoped to the MISSING paths by name:
    # it survives only where it is true, and it says exactly which path it excuses.*
    row["unwritten_paths_justified_by"] = (
        {"justification": "court_not_authored", "applies_to": missing} if missing else None)

    # AND THE TWO FIELDS THAT CONTRADICTED EACH OTHER ARE RECONCILED: prerequisites are complete
    # exactly when nothing declared is missing.
    row["internal_prerequisites_completed"] = not missing
    return row


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="recompute the blocked-task matrix")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args(argv)

    doc = json.loads(MATRIX.read_text(encoding="utf-8"))
    changed, offenders = [], []

    for row in doc["rows"]:
        before = (tuple(row.get("paths_that_exist") or []),
                  row.get("unwritten_paths_justified_by"),
                  row.get("internal_prerequisites_completed"))
        recompute(row)
        after = (tuple(row.get("paths_that_exist") or []),
                 row.get("unwritten_paths_justified_by"),
                 row.get("internal_prerequisites_completed"))
        if before != after:
            changed.append((row["task"], before, after))
        # A task with no declared paths at all is not "complete" -- it is undetermined, and that
        # must be visible rather than silently counted as satisfied.
        if not row.get("declared_regression_paths"):
            offenders.append(row["task"])

    for task, before, after in changed:
        print(f"  {task}: paths_that_exist {list(before[0])} -> {list(after[0])}")
        print(f"        justification {before[1]!r} -> {after[1]!r}   prerequisites {before[2]} -> {after[2]}")

    doc["counts"] = {
        "rows": len(doc["rows"]),
        "tasks_with_all_declared_courts_present": sum(
            1 for r in doc["rows"] if not r.get("paths_missing")),
        "tasks_with_a_missing_declared_court": sum(
            1 for r in doc["rows"] if r.get("paths_missing")),
        "tasks_declaring_no_paths": offenders,
    }
    doc["recomputed_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc["recompute_note"] = (
        "*** DERIVED FROM THE LIVE FILESYSTEM, NOT REMEMBERED. *** *The `paths_that_exist` and "
        "`court_not_authored` fields were a SNAPSHOT that nothing refreshed: the courts were "
        "authored in later rounds and these fields went on denying them, so a row named its court "
        "twice and denied it once. `scripts/recompute_blocked_matrix.py` measures each declared "
        "path per platform, so 'Android done, iOS owed' is expressible instead of collapsed.*")

    if args.write:
        MATRIX.write_text(json.dumps(doc, indent=1, ensure_ascii=False), encoding="utf-8")
        print(f"  wrote {MATRIX.relative_to(ROOT)}")
    print(f"  counts: {json.dumps(doc['counts'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
