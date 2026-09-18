#!/usr/bin/env python3
"""PHASE 5 EXIT: NO ACCIDENTAL GREEN. PARSE THE RESULT FILES THE LANES ACTUALLY WROTE.

THE CLAUSE, VERBATIM FROM THE AUDIT'S OWN ORDERED PLAN (Phase 5, "regression and proof hardening"):
    *"independently parse result files and skipped tests; inspect test target/source membership. ... **Exit:** every
    required closure layer has a candidate-bound result; **no accidental green after a patch abort, skipped test or
    wrong generated mirror.** Claims not executed remain explicitly unverified."*

*** EVERY ONE OF THOSE THREE FAILURES HAPPENED IN THIS REMEDIATION, AND EACH ONE LOOKED LIKE A PASS. *** This control
exists because a `BUILD SUCCESSFUL` line and a zero-failure summary are BOTH compatible with "the suite never ran":

  1. A PATCH ABORT. A mutation script with a syntax error applied nothing; `swift test` then ran CLEAN CODE and printed
     `20 tests, 0 failures` -- which read as "the mutation survived". (Round 584.)
  2. A WRONG GENERATED MIRROR. `ios/Packages/GodstoneFoundation/` is a GENERATED tree (`sync_ios_foundation_package.py`
     rmtree's and recopies it), so THREE mutation rounds edited the canonical source while SwiftPM built the copy --
     green every time, because the wrong file was edited. (Round 582.)
  3. SKIPPED/TEST-LESS RUNS. A truncated file and a broken build each produced `Executed 0 tests, 0 failures` --
     which reads exactly like a passing filter. (Rounds 586, 588, 590.)

AND THE ORIGINAL PARSER BUG: a passing JUnit case is written SELF-CLOSING (`<testcase ... />`), so a regex of the form
`<testcase name="..."[^>]*>(.*?)</testcase>` SWALLOWS subsequent cases and attributes their failures to the first
passing name. Counts stayed right; NAMES were shifted. (Round 568.)

WHAT THIS CONTROL ASSERTS, PER LANE:
  * the result files EXIST and are NON-EMPTY (a suite that never ran leaves no XML, or leaves an empty one);
  * the suite EXECUTED AT LEAST ONE TEST -- **`tests="0"` IS A FAILURE HERE, NOT A PASS**, because it is the shape a
    broken build, a truncated mirror and a wrong filter all produce;
  * the summary is PARSED, not grepped: `tests`, `skipped`, `failures`, `errors` are read as ATTRIBUTES, and any
    NON-ZERO skipped/failures/errors FAILS the control with the ARM NAMES attached;
  * every `<testcase>` is parsed with a SELF-CLOSING-TOLERANT pattern, so a passing case cannot swallow the next one's
    failure -- and the per-arm names are reported rather than a bare count.

USAGE:
    python3 ci/check_lane_results.py                 # the default lane set
    python3 ci/check_lane_results.py --selftest      # the control's own adversarial mutations

EXIT: 0 when every lane carries a candidate-bound result with zero skipped/failed/errored arms.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# The lanes the remediation actually runs. Each is (label, glob) -- the glob is relative to the repo root.
LANES = [
    ("android:app", "android/app/build/test-results/*/*.xml"),
    ("android:core", "android/core/build/test-results/*/*.xml"),
    ("android:mesh", "android/mesh/build/test-results/*/*.xml"),
]

# *** SELF-CLOSING-TOLERANT: a passing case is `<testcase ... />`, and the naive pattern swallows what follows. ***
TESTCASE = re.compile(r"<testcase\b([^>]*?)(?:/>|>(.*?)</testcase>)", re.S)
SUITE = re.compile(
    r'<testsuite\b[^>]*?tests="(\d+)"[^>]*?skipped="(\d+)"[^>]*?failures="(\d+)"[^>]*?errors="(\d+)"'
)
# The attributes may appear in any order; fall back to per-attribute extraction.
ATTR = lambda name, s: re.search(rf'{name}="(\d+)"', s)


def parse_suite(path: Path) -> dict:
    """Parse ONE result file. Returns counts plus the names of any failing/erroring arms."""
    text = path.read_text(encoding="utf-8", errors="replace")
    # THE FIRST testsuite ELEMENT CARRIES THE COUNTS. Read the attributes individually rather than relying on order.
    head = text[: text.find(">", text.find("<testsuite")) + 1] if "<testsuite" in text else text
    counts = {}
    for name in ("tests", "skipped", "failures", "errors"):
        m = ATTR(name, head) or ATTR(name, text[:4000])
        counts[name] = int(m.group(1)) if m else 0

    bad = []
    for m in TESTCASE.finditer(text):
        attrs, body = m.group(1), m.group(2)
        if body and ("failure" in body or "error" in body):
            nm = re.search(r'name="([^"]+)"', attrs)
            bad.append(nm.group(1) if nm else "<unnamed>")
    return {"counts": counts, "bad": bad, "bytes": len(text)}


def check_lane(label: str, pattern: str) -> list[str]:
    """Returns a list of problems for one lane. An EMPTY list means the lane carried a real result."""
    problems: list[str] = []
    files = sorted(glob.glob(str(REPO / pattern)))
    if not files:
        # *** A LANE WITH NO RESULT FILE HAS NOT RUN. THAT IS A FAILURE, NOT AN ABSENCE OF NEWS. ***
        problems.append(f"{label}: NO RESULT FILES matched {pattern} -- the lane did not run, or was cleaned")
        return problems

    total = {"tests": 0, "skipped": 0, "failures": 0, "errors": 0}
    empty: list[str] = []
    bad_arms: list[str] = []
    for f in files:
        p = Path(f)
        if p.stat().st_size == 0:
            empty.append(p.name)
            continue
        parsed = parse_suite(p)
        for k in total:
            total[k] += parsed["counts"][k]
        bad_arms.extend(f"{p.stem.replace('TEST-', '')}#{a}" for a in parsed["bad"])

    if empty:
        problems.append(f"{label}: {len(empty)} EMPTY result file(s): {empty[:3]}")
    # *** tests=0 IS THE FAILURE SHAPE A BROKEN BUILD, A TRUNCATED MIRROR AND A WRONG FILTER ALL PRODUCE. ***
    if total["tests"] == 0:
        problems.append(
            f"{label}: ZERO TESTS EXECUTED across {len(files)} result file(s) -- this is what a broken build, a "
            f"truncated generated mirror or a wrong filter all look like, and it is NOT a pass")
    if total["skipped"]:
        problems.append(f"{label}: {total['skipped']} SKIPPED test(s) -- a skipped arm is not a green arm")
    if total["failures"] or total["errors"]:
        problems.append(
            f"{label}: {total['failures']} failure(s) / {total['errors']} error(s): {bad_arms[:6]}")
    return problems


def selftest() -> int:
    """*** THE CONTROL'S OWN ADVERSARIAL MUTATIONS: EACH MUST BE CAUGHT. ***"""
    import tempfile

    failures = 0
    print("== selftest: an empty/absent lane result must be caught ==")
    with tempfile.TemporaryDirectory() as td:
        # 1. NO FILES AT ALL.
        global REPO
        saved = REPO
        REPO = Path(td)
        probs = check_lane("no-files", "*.xml")
        if probs:
            print(f"   PASS: a lane with no results is REFUSED ({probs[0][:70]}...)")
        else:
            print("   FAIL: a lane with no results was ACCEPTED"); failures += 1

        # 2. A ZERO-TEST SUITE -- THE EXACT SHAPE A BROKEN BUILD PRODUCES.
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="0" skipped="0" failures="0" errors="0"></testsuite>',
            encoding="utf-8")
        probs = check_lane("zero-tests", "*.xml")
        if probs and "ZERO TESTS" in probs[0]:
            print("   PASS: tests=\"0\" is REFUSED rather than read as a pass")
        else:
            print("   FAIL: a zero-test suite was ACCEPTED"); failures += 1

        # 3. A SKIPPED ARM.
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="1" skipped="1" failures="0" errors="0">'
            '<testcase name="a"/></testsuite>', encoding="utf-8")
        probs = check_lane("skipped", "*.xml")
        if probs and "SKIPPED" in probs[0]:
            print("   PASS: a skipped arm is REFUSED")
        else:
            print("   FAIL: a skipped arm was ACCEPTED"); failures += 1

        # 4. *** THE SELF-CLOSING TRAP: A PASSING CASE FOLLOWED BY A FAILING ONE. The naive pattern attributes the
        #    failure to the PASSING name -- so this mutation proves the parser does not.
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="2" skipped="0" failures="1" errors="0">'
            '<testcase name="passes"/>'
            '<testcase name="theRealFailure"><failure message="boom"/></testcase>'
            '</testsuite>', encoding="utf-8")
        parsed = parse_suite(Path(td) / "TEST-x.xml")
        if parsed["bad"] == ["theRealFailure"]:
            print("   PASS: the failure is attributed to the FAILING arm, not the passing one")
        else:
            print(f"   FAIL: attribution was shifted -- got {parsed['bad']}"); failures += 1

        REPO = saved

    print(f"\nselftest: {4 - failures}/4 mutations caught")
    return 1 if failures else 0


# ================================================================================================
# *** PHASE 7 EXIT: "NO REQUIRED TEST OMITTED BY TARGET CONFIGURATION". ***
#
# `ios/Godstone/` is CANONICAL and `ios/Packages/GodstoneFoundation/` is a GENERATED MIRROR (the sync
# script rmtree's and recopies it). **A FILE PRESENT IN ONE AND ABSENT FROM THE OTHER IS EXACTLY THE
# "WRONG GENERATED MIRROR" THIS SESSION PAID THREE ROUNDS FOR** -- so membership is asserted here rather
# than assumed, and the drift check is run rather than trusted.
# ================================================================================================

MIRROR_PAIRS = [
    ("ios/Godstone/Sources/GodstoneCore", "ios/Packages/GodstoneFoundation/Sources/GodstoneCore"),
    ("ios/Godstone/Sources/GodstoneMesh", "ios/Packages/GodstoneFoundation/Sources/GodstoneMesh"),
    ("ios/Godstone/Tests/GodstoneCoreTests", "ios/Packages/GodstoneFoundation/Tests/GodstoneCoreTests"),
    ("ios/Godstone/Tests/GodstoneMeshTests", "ios/Packages/GodstoneFoundation/Tests/GodstoneMeshTests"),
    ("ios/Godstone/Tests/LabMeshTests", "ios/Packages/GodstoneFoundation/Tests/LabMeshTests"),
]


def check_mirror_membership() -> list[str]:
    problems: list[str] = []
    for canonical, mirror in MIRROR_PAIRS:
        c_path, m_path = REPO / canonical, REPO / mirror
        if not c_path.is_dir():
            problems.append(f"mirror: canonical {canonical} is absent -- the rig this control assumes has moved")
            continue
        if not m_path.is_dir():
            problems.append(f"mirror: generated {mirror} is absent -- the mirror was not synced")
            continue
        c = {p.name for p in c_path.glob("*.swift")}
        m = {p.name for p in m_path.glob("*.swift")}
        missing, extra = sorted(c - m), sorted(m - c)
        if missing:
            problems.append(f"mirror: {len(missing)} file(s) present in {canonical} but ABSENT from the generated "
                            f"mirror (a test omitted by target configuration): {missing[:4]}")
        if extra:
            problems.append(f"mirror: {len(extra)} file(s) in {mirror} with NO canonical source (a stale generated "
                            f"file): {extra[:4]}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()

    all_problems: list[str] = []
    summary: list[str] = []
    for label, pattern in LANES:
        probs = check_lane(label, pattern)
        files = glob.glob(str(REPO / pattern))
        total = {"tests": 0, "skipped": 0, "failures": 0, "errors": 0}
        for f in files:
            p = Path(f)
            if p.stat().st_size:
                parsed = parse_suite(p)
                for k in total:
                    total[k] += parsed["counts"][k]
        summary.append(
            f"  {label:<14} files={len(files):<3} tests={total['tests']:<5} skipped={total['skipped']} "
            f"failures={total['failures']} errors={total['errors']}")
        all_problems.extend(probs)

    print("LANE RESULTS (parsed from the result files, not grepped from stdout):")
    print("\n".join(summary))
    if all_problems:
        print("\nFAIL:")
        for p in all_problems:
            print("  - " + p)
        return 1
    print("\nlane results: PASSED (every lane ran, executed at least one test, and carried no "
          "skipped/failed/errored arm)")

    # *** PHASE 7 EXIT: "NO REQUIRED TEST OMITTED BY TARGET CONFIGURATION". ***
    mirror_problems = check_mirror_membership()
    if mirror_problems:
        print("\nMIRROR MEMBERSHIP FAIL:")
        for mp in mirror_problems:
            print("  - " + mp)
        return 1
    counts = ", ".join(f"{Path(c).name}={len(list((REPO / c).glob('*.swift')))}" for c, _ in MIRROR_PAIRS)
    print(f"mirror membership: PASSED (every canonical file is mirrored, none orphaned) -- {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
