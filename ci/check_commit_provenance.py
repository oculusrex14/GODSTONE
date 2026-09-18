#! /usr/bin/env python3
"""GS-FINAL-013: the provenance annotation's own court.

THE AUDIT'S REGRESSION CLAUSE, VERBATIM: *"Check the annotation references the exact immutable commit and does not
change historical SHA references."*

AND ITS REMEDY, WHICH THIS CONTROL ALSO ENFORCES: *"Do not amend or rebase."* The commit MUST still exist with the same
object id, and it MUST still carry the debris -- because a control that passed after someone quietly amended the
message would be certifying the very act the finding forbids.

A THIRD CHECK IS THE ONE THAT MAKES THE ANNOTATION WORTH HAVING: the diff's bounded scope. The annotation claims the
commit changed ONE documentation file and NO executable product source. That claim is recomputed here from the commit
itself, so the annotation cannot drift from the thing it describes.

Usage:
    python3 ci/check_commit_provenance.py [--json]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANNOTATION = ROOT / "docs" / "remediation" / "COMMIT_3eb1904_PROVENANCE.md"

CORRUPT_SHA = "3eb1904b133c26137f68da6c0b82a0424d0095e1"
# The accidental prefix ends and the intended message begins at this EXACT line, measured once and pinned here.
INTENDED_MESSAGE_FIRST_LINE = "T78 convergence: the terminal state, with one clean exact candidate SHA per scope"
EXECUTABLE_SUFFIXES = (".swift", ".kt", ".kts", ".py", ".rs", ".c", ".cpp", ".h", ".m", ".mm", ".java")


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True).stdout


def audit() -> dict:
    errors: list[str] = []
    checks = 0

    # (1) THE COMMIT STILL EXISTS AT THE SAME OBJECT ID -- "do not amend or rebase" is a *measurable* prohibition.
    checks += 1
    kind = git("cat-file", "-t", CORRUPT_SHA).strip()
    if kind != "commit":
        errors.append("the annotated commit %s resolveth to %r, not a commit -- the history was REWRITTEN, which the "
                      "audit forbids by name" % (CORRUPT_SHA[:12], kind))
        return {"checks": checks, "errors": errors}

    # (2) AND IT STILL CARRIES THE DEBRIS. A control that passed on an amended message would certify the act forbidden.
    checks += 1
    message = git("log", "-1", "--format=%B", CORRUPT_SHA)
    if "import sys, re" not in message:
        errors.append("the commit no longer carrieth the shell/Python debris -- THE MESSAGE WAS AMENDED, and a "
                      "rewritten message invalidates every SHA that cites this commit")

    checks += 1
    if INTENDED_MESSAGE_FIRST_LINE not in message:
        errors.append("the commit no longer carrieth its INTENDED message (%r) -- the annotation maps a body that is "
                      "no longer there" % INTENDED_MESSAGE_FIRST_LINE[:40])

    # (3) THE ANNOTATION REFERENCES THE EXACT IMMUTABLE SHA.
    checks += 1
    if not ANNOTATION.exists():
        errors.append("no provenance annotation at %s" % ANNOTATION.relative_to(ROOT))
    else:
        text = ANNOTATION.read_text(encoding="utf-8")
        checks += 1
        if CORRUPT_SHA not in text:
            errors.append("the annotation does not name the exact immutable SHA %s" % CORRUPT_SHA)
        checks += 1
        if not re.search(r"do not amend or rebase|Do not amend or rebase", text):
            errors.append("the annotation does not record the audit's own prohibition against amending or rebasing")

        # (4) THE BOUNDED DIFF CLAIM IS RECOMPUTED FROM THE COMMIT, so the annotation cannot drift from it.
        checks += 1
        changed = [p for p in git("show", "--name-only", "--format=", CORRUPT_SHA).splitlines() if p.strip()]
        executable = [p for p in changed if p.endswith(EXECUTABLE_SUFFIXES)
                      and not p.startswith(("docs/", "ci/", "tests/"))]
        if executable:
            errors.append("the commit changed EXECUTABLE PRODUCT SOURCE (%s), so the annotation's documentation-only "
                          "claim is false" % executable)
        checks += 1
        if "T78_CONVERGENCE.md" not in " ".join(changed):
            errors.append("the commit did not touch T78_CONVERGENCE.md, so the annotation's intended-subject mapping "
                          "is wrong")

    return {"checks": checks, "errors": errors, "sha": CORRUPT_SHA,
            "changed_files": [p for p in git("show", "--name-only", "--format=", CORRUPT_SHA).splitlines() if p.strip()]}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="the commit-provenance annotation's own court")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    r = audit()
    failed = bool(r["errors"])
    if args.json:
        print(json.dumps(r, indent=1, ensure_ascii=False))
        return 1 if failed else 0
    for e in r["errors"]:
        print("::error::%s" % e)
    print("commit provenance: %d check(s) | %s | changed: %s"
          % (r["checks"], r["sha"][:12], ", ".join(r.get("changed_files", [])) or "?"))
    if failed:
        print("commit provenance: FAILED (%d defect(s))" % len(r["errors"]))
        return 1
    print("commit provenance: PASSED (the commit is unrewritten, still carrieth its debris AND its intended message, "
          "and the bounded documentation-only diff is confirmed from the commit itself)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
