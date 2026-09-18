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
import hashlib
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# The lanes the remediation actually runs. Each is (label, task-dir, glob).
#
# *** THE GLOB NAMES THE EXACT TASK DIRECTORY, NOT A WILDCARD (round 745). ***
#
# *The entries used to read `.../test-results/*/*.xml`, AND THAT SINGLE `*` WAS THE INFLATION MECHANISM:* **a FILTERED run
# (`--tests ...`, which the courts and mutation harness use) writes its reports into a SIBLING directory beside the lane's
# own** -- `mesh-di/`, `mesh-identity/`, `testLightDebugUnitTest/` -- *and the wildcard summed those in as lane evidence.*
# **MEASURED: `android:mesh` reported `files=108 tests=1906` while its SOURCES declare 1273 `@Test`s and its 80
# `@Test`-bearing classes write 80 files;** *deleting the results root and letting ONE generation rebuild it gave 80/1273,
# twice.* *The app lane carrieth the same pollution on a smaller scale (`100` vs the honest `96`)*, and **the stray
# directory that caused it was listed in this very build tree.**
#
# **SO THE LANE NAMES ITS TASK DIRECTORY EXACTLY, and an UNEXPECTED SIBLING IS REFUSED BY NAME** -- *because a control
# that quietly sums a directory it was not told about is a control whose denominator nobody can compute.*
LANES = [
    ("android:app", "testLightDebugUnitTest", "android/app/build/test-results/testLightDebugUnitTest/*.xml"),
    ("android:core", "testDebugUnitTest", "android/core/build/test-results/testDebugUnitTest/*.xml"),
    ("android:mesh", "testDebugUnitTest", "android/mesh/build/test-results/testDebugUnitTest/*.xml"),
]

# *** AND THE iOS LANE, WHICH THIS CONTROL DID NOT COVER AT ALL (round 691). ***
#
# **MEASURED: `LANES` NAMED THREE ANDROID LANES AND NOTHING ELSE -- SO "lane results PASSED" SAID NOTHING ABOUT iOS,
# WHILE I CITED IT BESIDE AN iOS CLAIM.** *And the iOS claim itself came from a grep that could only print failures:*
# `grep -E "error: |Executed [0-9]+ tests, with [1-9]"` **matché NEITHER ALTERNATIVE on a green run**, so the output was
# empty whether the lane passed or died early -- *absence of output reported as success.*
#
# **`swift test` WRITETH NO xunit FILE (measured: no `*.xml` under `.build`), SO THE LOG IS THE ARTIFACT** and this
# control parses IT. The pattern is written to be satisfied ONLY by a real aggregate line:
#     "Executed 1242 tests, with 0 failures (0 unexpected) in 103.478 (103.537) seconds"
# *so a run that died before the suites finish -- which prints errors and NO such line -- is REFUSED rather than
# silently passing.*
IOS_LOG = REPO / "ios-lane.log"

#: The trees whose bytes the iOS lane compiles. **A SOURCE NEWER THAN THE LOG IS A SOURCE THE LOG NEVER SAW.**
IOS_SOURCE_TREES = (
    "ios/Godstone/Sources",
    "ios/Godstone/Tests",
    "ios/Packages/GodstoneFoundation/Sources",
    "ios/Packages/GodstoneFoundation/Tests",
)
IOS_SUITE = re.compile(r"^Test Suite '(\w+)\.xctest' passed", re.M)
IOS_TOTAL = re.compile(r"^\s*Executed (\d+) tests?, with (\d+) failures? \(\d+ unexpected\)", re.M)


def check_ios_lane() -> tuple[list[str], dict]:
    """Parse the iOS log: three suites must PASS and the totals must carry tests with zero failures."""
    problems: list[str] = []
    totals = {"suites": 0, "tests": 0, "failures": 0}
    if not IOS_LOG.is_file():
        return ([f"the iOS lane log is absent at {IOS_LOG} -- the lane has not been run, and AN UNRUN LANE IS NOT A "
                 f"PASS"], totals)
    text = IOS_LOG.read_text(encoding="utf-8", errors="replace")
    # EVERY SUITE THAT PRINTED A RESULT MUST HAVE PASSED.
    passed = IOS_SUITE.findall(text)
    totals["suites"] = len(passed)
    for name in ("GodstoneMeshTests", "GodstoneCoreTests", "LabMeshTests"):
        if name not in passed:
            problems.append(f"the iOS lane carrieth no PASSED line for suite {name} -- a suite that did not run "
                            f"(or did not pass) is not covered by this control")
    # *** AND THE AGGREGATE LINES ARE COUNTED AT THE OUTERMOST LEVEL ONLY (round 695). ***
    #
    # **MEASURED: THE 90 `Executed` LINES IN THE LOG SUM TO 4023 WHILE THE LANE'S TRUE TOTAL IS 1341** -- *XCTest's
    # nested suites RE-PRINT their children, so a suite's `Executed` line carrieth the sum of its cases AND each case's
    # test class printeth its own.* **SUMMING THEM OVER-COUNTS BY EXACTLY THE NESTING DEPTH**, and `swift test` ends with
    # the outermost total per xctest bundle:
    #     Test Suite 'GodstoneMeshTests.xctest' passed  ->  Executed 1242 tests, with 0 failures
    #     Test Suite 'GodstoneCoreTests.xctest' passed  ->  Executed   94 tests, with 0 failures
    #     Test Suite 'LabMeshTests.xctest' passed       ->  Executed    5 tests, with 0 failures
    # **SO THE PARSE TAKES EACH **xctest BUNDLE**'S OWN TOTAL, AND NOTHING ELSE.** *A number that over-counts is the
    # same defect class as one that under-counts: a total nobody can reconcile with the artifact.*
    run: list[tuple[int, int]] = []
    for name in ("GodstoneMeshTests", "GodstoneCoreTests", "LabMeshTests"):
        m = re.search(r"^Test Suite '" + name + r"\.xctest' passed.*?^\s*Executed (\d+) tests?, with (\d+) failures?",
                      text, re.M | re.S)
        if m:
            run.append((int(m.group(1)), int(m.group(2))))
    if not run:
        problems.append("the iOS lane log carrieth NO per-bundle 'Executed N tests, with M failures' total -- the run "
                        "died before its suites finished, which is exactly what a truncated or broken lane looks like")
    for tests, failures in run:
        totals["tests"] += tests
        totals["failures"] += failures
    # AND THE REAL AGGREGATE LINES ARE CARRIED ALONGSIDE THE PARSE, so a reader can reconcile the two without
    # re-deriving them -- *the cross-check, not a substitute for it.*
    totals["evidence"] = [f"{t} tests / {f} failures" for t, f in run]
    if totals["tests"] == 0:
        problems.append("the iOS lane executed ZERO tests -- a zero-test run has not measured anything")
    for name, n in re.findall(r"^\s*Executed (\d+) tests?, with (\d+) failures?", text, re.M):
        if int(name) and int(n):
            problems.append(f"the iOS lane carrieth a failing count: {name} tests, {n} failures")
    if re.search(r"^.*error: ", text, re.M):
        problems.append("the iOS lane log carrieth `error:` lines")

    # *** AND THE LOG MUST BE FRESHER THAN THE SOURCE IT CLAIMS TO HAVE TESTED (round 697). ***
    #
    # **MEASURED, THIS WAS THE SAME "GREEN ON STALE EVIDENCE" CLASS THE LANE CONTROL WAS BUILT TO PREVENT: a log dated
    # 2020 PASSED**, because nothing bound it to the tree. *The three Android lanes read `build/test-results/`, which a
    # `--rerun-tasks` build REPLACES, so they carry their own recency -- but the iOS log is a file that persisteth
    # across edits.*
    #
    # **THE BINDING IS A CONTENT DIGEST OF THE SOURCES, NOT THEIR MTIMES.** *MTIME WAS THE FIRST ATTEMPT AND IT IS
    # NOISY: a `git checkout`, a mirror sync or a `touch` moveth an mtime WITHOUT changing a byte, so it would refuse
    # a genuinely-current lane -- and a control that reddens spuriously getteth switched off.* **A DIGEST CHANGETH ONLY
    # WHEN THE BYTES DO**, so it is exactly as strong and far less brittle.
    #
    # **THE SIDECAR IS WRITTEN BY THE LANE RUNNER** (`<log>.sources.sha256`), which is the honest place for it: *the
    # runner KNOWETH which tree it compiled, and the control can only CHECK.* **AN ABSENT SIDECAR IS REFUSED**, because
    # a log with no provenance is a log nobody can date.
    sidecar = IOS_LOG.with_suffix(IOS_LOG.suffix + ".sources.sha256")
    current = _ios_source_digest()
    if not sidecar.is_file():
        problems.append(
            f"the iOS lane log carrieth NO SOURCE DIGEST at {sidecar.name} -- *a log with no provenance cannot be "
            f"dated, and an undatable log is not evidence about the current tree*")
    else:
        recorded = sidecar.read_text(encoding="utf-8").strip()
        if recorded != current:
            problems.append(
                f"the iOS lane log is STALE: its source digest {recorded[:16]}… does not match the tree's "
                f"{current[:16]}… -- *the log never saw these sources, so it is not evidence about them. Re-run the "
                f"lane.*")
    return problems, totals

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
    for label, task_dir, pattern in LANES:
        probs = check_lane(label, pattern)
        files = glob.glob(str(REPO / pattern))
        # *** AND AN UNEXPECTED SIBLING UNDER `test-results/` IS REFUSED BY NAME (round 745). ***
        #
        # *A sibling means SOMEONE RAN A FILTERED SUITE beside the lane* -- the courts and the mutation harness both do --
        # **and while the glob above no longer sums it, its PRESENCE is the warning that the lane's own directory may be a
        # partial generation.** *This is the same "two trees, one claim" shape that let a stray report directory inflate
        # the mesh lane to 1906 for eight verifications.*
        results_root = (REPO / pattern).parent.parent
        if results_root.is_dir():
            siblings = sorted(d.name for d in results_root.iterdir()
                              if d.is_dir() and d.name != task_dir)
            if siblings:
                all_problems.append(
                    f"{label}: `{results_root.relative_to(REPO)}` carrieth UNEXPECTED SIBLING DIRECTORIES {siblings} "
                    f"-- *a filtered run wrote beside the lane's own `{task_dir}`, and a sibling is how this lane's count "
                    f"was inflated before. Clear `build/test-results/` and run the lane alone.*")
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
        # *** AND THE ANDROID LANES ARE BOUND TO THEIR SOURCES TOO (round 697). ***
        #
        # **MEASURED: 155 Kotlin sources under `android/mesh/src` were NEWER than that lane's result XML** -- *the
        # mtimed artifact carrieth no provenance, so a stale result file passeth exactly as an iOS stale log did.*
        # **`--rerun-tasks` REPLACES the XML on a real run, but nothing ASSERTETH that the replacement happened.**
        # *So the same digest sidecar the iOS lane carrieth is written for each Android lane by
        # `tools/readiness/run_android_lanes.sh`, and an absent or divergent digest is REFUSED.*
        all_problems.extend(_android_source_digest_problems(label))
        # *** GS-CTRL-002 (round 719): AND THE COUNT IS BOUND TO THE SOURCES, NOT ONLY THE FILES TO THEM. ***
        #
        # **MEASURED: `android:mesh` reported `files=108 tests=1906` WHILE THE MODULE'S TEST SOURCES CARRY EXACTLY
        # 1273 `@Test` ANNOTATIONS AND ITS 80 `@Test`-BEARING CLASSES WRITE 80 RESULT FILES.** *Deleting the results
        # directory and re-running -- WITH `--rerun-tasks`, which the runner already passeth -- produced 80/1273 again.*
        # **SO THE HIGHER NUMBER WAS NEVER A BIGGER SUITE: IT WAS STALE XMLS FROM A SIBLING TASK DIRECTORY ACCUMULATING,
        # because the glob `test-results/*/*.xml` matchéth ANY task dir.** *** AND A COUNT THAT ONLY EVER GROWS, BECAUSE
        # NOTHING REMOVETH THE DEAD FILES, IS A COUNT THAT CANNOT BE FALSIFIED -- *the same class as the stale log, one
        # path over: the digest bindeth the SOURCES to the result, and THIS bindeth the COUNTS to the sources, because a
        # stale sibling directory carrieth a CURRENT digest happily.* ***
        expected = _source_test_census(label)
        if expected is not None and total["tests"] != expected:
            all_problems.append(
                f"{label}: reports {total['tests']} tests but its SOURCES declare {expected} `@Test`s -- *a count that "
                f"disagreeth with the sources is counting stale result files from a sibling task directory, or did not "
                f"run them all. Clear `build/test-results/` and re-run the lane.*")

    ios_probs, ios_totals = check_ios_lane()
    summary.append(
        f"  {'ios:foundation':<14} suites={ios_totals['suites']:<3} tests={ios_totals['tests']:<5} "
        f"failures={ios_totals['failures']}  <- per bundle: " + "; ".join(ios_totals.get("evidence", [])))
    all_problems.extend(ios_probs)

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



def _ios_source_digest() -> str:
    """A digest over every byte the iOS lane compiles -- path-sorted, so it is order-stable."""
    h = hashlib.sha256()
    for rel in IOS_SOURCE_TREES:
        base = REPO / rel
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*.swift")):
            if f.name.endswith(".swift") is False:
                continue
            h.update(str(f.relative_to(REPO)).encode())
            h.update(b"\0")
            h.update(f.read_bytes())
            h.update(b"\0")
    return h.hexdigest()

#: The production tree each Android lane compiles. *A source newer than the result file is a source the lane never saw.*
ANDROID_SOURCE_TREES = {
    "android:app": ("android/app/src",),
    "android:core": ("android/core/src",),
    "android:mesh": ("android/mesh/src",),
}


def _android_source_digest(label: str) -> str:
    h = hashlib.sha256()
    for rel in ANDROID_SOURCE_TREES.get(label, ()):
        base = REPO / rel
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*.kt")):
            h.update(str(f.relative_to(REPO)).encode())
            h.update(b"\0")
            h.update(f.read_bytes())
            h.update(b"\0")
    return h.hexdigest()


def _android_source_digest_problems(label: str) -> list[str]:
    """The lane's result files must have been produced from THESE sources, not from a revision nobody can date."""
    safe = label.replace(":", "-")
    sidecar = REPO / f"{safe}.sources.sha256"
    current = _android_source_digest(label)
    if not sidecar.is_file():
        return [f"{label}: no source digest at {sidecar.name} -- *a result with no provenance cannot be dated, and an "
                f"undatable result is not evidence about the current tree. Run tools/readiness/run_android_lanes.sh.*"]
    recorded = sidecar.read_text(encoding="utf-8").strip()
    if recorded != current:
        return [f"{label}: STALE -- its source digest {recorded[:16]}… does not match the tree's {current[:16]}… -- "
                f"*the results never saw these sources. Re-run the lane.*"]
    return []


#: The test tree each lane compiles, for the SOURCE-side census below.
LANE_TEST_SOURCES = {
    "android:app": "android/app/src/test",
    "android:core": "android/core/src/test",
    "android:mesh": "android/mesh/src/test",
}


def _source_test_census(label: str) -> int | None:
    """How many `@Test`s the lane's own sources declare -- the count a CURRENT run must reproduce.

    *Anchored on `@Test` because that is what maketh a method a test: a lane reporting MORE than this is counting stale
    XML from a sibling task directory, and one reporting fewer did not run them all.*
    """
    base = REPO / LANE_TEST_SOURCES.get(label, "")
    if not base.is_dir():
        return None
    total = 0
    for f in base.rglob("*.kt"):
        total += f.read_text(encoding="utf-8").count("@Test")
    return total

if __name__ == "__main__":
    sys.exit(main())
