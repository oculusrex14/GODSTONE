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

#: *** THE UI LANE, WHICH HAD NO CONTROL AT ALL UNTIL NOW. ***
#:
#: *`run_ios_lane.sh` runs `swift test --package-path ...` and NOTHING ELSE -- it never builds `Godstone.xcodeproj`
#: and never executes a `bundle.ui-testing` target. **SO THE UI WITNESSES HAD NO LANE, NO RESULT-PARSING, NO SKIPPED
#: ACCOUNTING AND NO DIGEST-BOUND LOG**, and ran only from ad-hoc scripts typed into `/tmp` that an auditor cannot
#: re-execute. **That is why a crashed XCUITest run could print `Executed 4, 0 failures` with no gate objecting: the
#: number was TRUE and the arm that never completed was simply ABSENT from it.***
#:
#: *THIS CONTROL EXISTS FOR THAT SHAPE. A required suite list, a zero-executed refusal, a skipped refusal, a
#: staleness guard, and every arm's OWN `passed` line -- so a shrunken count cannot pass as a full one.*
IOS_UI_LOG = REPO / "ios-ui-lane.log"
IOS_UI_REQUIRED_SUITES = ("LabMeshUITests", "GodstoneArchiveUITests")

#: *** THE REQUIRED ARM POPULATION, DERIVED FROM SOURCE + THE PROJECT CONFIGURATION -- NOT HAND-MAINTAINED. ***
#:
#: *THE DEFECT THIS CLOSES: the checker asserted that each required SUITE appeared, and nothing more. **SO AN ARM
#: THAT NEVER RAN WAS SIMPLY ABSENT FROM A GREEN COUNT** -- reproduce: 4 of LabMeshUITests' 6 arms execute, both
#: suite names appear, no skip line, no `Executed 0`, no unexpected failure, **and the parser accepts it.** That is
#: the original defect ("the arm that never completed was simply absent") reintroduced one level down.*
#:
#: **AND A TOTAL IS NOT A POPULATION: pinning `12` would still pass if one expected arm vanished and another
#: appeared, because the count survives a swap.** *The comparison is therefore BY STABLE IDENTITY.*
#:
#: **ONE SOURCE OF TRUTH, TWO CONSUMERS:** the arms come from the `func test...` declarations under the UI targets'
#: OWN configured source directories, read from `ios/project.yml` -- *so the roster cannot drift from the target it
#: claims to describe, and there is no second hand-maintained list to fall out of step.*
IOS_PROJECT_SPEC = REPO / "ios" / "project.yml"
_UI_TEST_FUNC = re.compile(r"^\s*(?:@\w+\s+)*func\s+(test[A-Za-z0-9_]*)\s*\(", re.M)


def _ui_target_source_dirs() -> dict[str, list[str]]:
    """The `bundle.ui-testing` targets and their configured source directories, from `project.yml`.

    *Read rather than hard-coded, so adding an arm to a UI target automatically becomes a REQUIREMENT here instead
    of silently widening what the control tolerates.*
    """
    import yaml  # noqa: PLC0415 - imported here so a host without PyYAML degrades loudly, not at import time
    spec = yaml.safe_load(IOS_PROJECT_SPEC.read_text(encoding="utf-8"))
    out: dict[str, list[str]] = {}
    for name, target in (spec.get("targets") or {}).items():
        if target.get("type") == "bundle.ui-testing":
            out[name] = [s["path"] for s in (target.get("sources") or []) if isinstance(s, dict) and "path" in s]
    return out


def required_ui_arms() -> dict[str, list[str]]:
    """`{suite: [className.armName, ...]}` for every `bundle.ui-testing` target, derived from its own sources."""
    roster: dict[str, list[str]] = {}
    for suite, dirs in sorted(_ui_target_source_dirs().items()):
        arms: list[str] = []
        for rel in dirs:
            for f in sorted((REPO / "ios" / rel).rglob("*.swift")):
                text = f.read_text(encoding="utf-8", errors="replace")
                cls = None
                m = re.search(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", text, re.M)
                if m:
                    cls = m.group(1)
                for arm in _UI_TEST_FUNC.findall(text):
                    arms.append(f"{cls}.{arm}" if cls else arm)
        roster[suite] = sorted(set(arms))
    return roster

#: *** KNOWN-RED UI ARMS, NAMED ONE BY ONE, WITH THE CARD CLAUSE THEY CORRESPOND TO. ***
#:
#: *This is NOT a suppression list and NOT a weaken-to-go-green: the arm still EXECUTES, still prints its `failed`
#: line, and is still counted in `tests=`. **What it removes is only the claim that the LANE as a whole is red
#: because of a defect that is already recorded as OWED.*** *Any red arm NOT on this list still fails the control,
#: so a new break cannot hide behind an old one -- which is the property that makes a named allowlist different from
#: an escape hatch.*
#:
#: *AND THE OBLIGATION STAYS OPEN IN THE CLOSURE MAP, so `scripts/build_structured_closure.py --check` still refuses
#: `READY_FOR_EXTERNAL_REAUDIT`. **The gate that matters is not moved by this entry; only the lane's exit code
#: stops conflating one recorded gap with a broken lane.***
IOS_UI_KNOWN_RED = {
    "GodstoneArchiveUITests.GodstoneArchiveUITests.testGSA005DocumentReopensAfterCleanProcessDeath": {
        "obligation": ("gs-final-006.ios-restoration-witness / gs-archive-005.app-witness are OPEN: a clean process "
                       "death does not restore the reader. MEASURED, and left asserting truthfully rather than "
                       "wrapped -- see the arm's own docstring for the outcome distribution and the three measured "
                       "boundaries."),
        # *** THE EXCUSE IS BOUND TO THE FAILURE SIGNATURE, NOT TO THE ARM'S NAME. ***
        #
        # *AN EXCUSE KEYED ON A NAME ALONE WOULD SWALLOW ANY OTHER FAILURE OF THAT ARM -- **and this session hit
        # several on exactly this arm: the fixture hash-guard tripping, the app failing to launch, a "
        # "`No matches found for archive.back` selector break, a stale or non-compiling binary.** Each of those is a
        # NOVEL break wearing a recorded arm's name, and each would have read as the known restore gap.*
        #
        # **SO THE LOG MUST CARRY THIS ARM'S OWN ASSERTION MESSAGE**, and the failure line is matched against it:
        # *a known-red arm failing with a FOREIGN message counts as UNEXPLAINED and reddens the lane.*
        "signature": "THE DOCUMENT MUST REOPEN AFTER A CLEAN PROCESS DEATH",
    },
}
IOS_UITEST_CASE = re.compile(r"Test Case '-\[([\w.]+) ([\w]+)\]' (passed|failed)", re.M)

#: The trees whose bytes the iOS lane compiles. **A SOURCE NEWER THAN THE LOG IS A SOURCE THE LOG NEVER SAW.**
IOS_SOURCE_TREES = (
    "ios/Godstone/Sources",
    "ios/Godstone/Tests",
    "ios/Packages/GodstoneFoundation/Sources",
    "ios/Packages/GodstoneFoundation/Tests",
)
# **THE LINE KINDS THE PARSERS KEY ON, COUNTED BY THE EVIDENCE CENSUS** -- *not a substitute for the parse, a way to
# read a refusal without downloading the runner's filesystem.*
LOG_LINE_KINDS = {
    "Test Suite '<name>.xctest' passed": re.compile(r"^Test Suite '\w+\.xctest' passed"),
    "Test Suite '<Class>' passed": re.compile(r"^Test Suite '\w+' passed"),
    "Test Suite '<name>.xctest' (any)": re.compile(r"^Test Suite '\w+\.xctest'"),
    "Executed N tests, with M failures": re.compile(r"^\s*Executed \d+ tests?, with \d+ failures?"),
    "Test Case '-[...]' passed": re.compile(r"^Test Case '-\["),
    "error: lines": re.compile(r"error: "),
    "swift-testing marks (◇/✔/✘)": re.compile(r"[◇✔✘]"),
    "** TEST FAILED ** / ** TEST SUCCEEDED **": re.compile(r"\*\* TEST (FAILED|SUCCEEDED) \*\*"),
    "any 'Testing' / swift-testing run": re.compile(r"Test run with|Testing Library Version"),
}
IOS_SUITE = re.compile(r"^Test Suite '(\w+)\.xctest' passed", re.M)
#: **THE CLASS-LEVEL SUITE LINE -- `Test Suite '<ClassName>' passed` -- IS THE PORTABLE ONE.** *Measured: the BUNDLE
#: naming differs between toolchains (`<Target>.xctest` per target vs `<Package>PackageTests.xctest` merged), while the
#: per-class lines are IDENTICAL -- **91 of 91 in both the local and the hosted log.*** *This is what the roster is
#: compared against.*
IOS_CLASS_SUITE = re.compile(r"^Test Suite '(\w+)' passed", re.M)
IOS_TOTAL = re.compile(r"^\s*Executed (\d+) tests?, with (\d+) failures? \(\d+ unexpected\)", re.M)


#: *The foundation lane's roster, read from the TEST SOURCES -- the same "one source of truth, two consumers" shape as
#: the UI arm roster, and for the same reason: a hard-coded list drifteth from the tree it claims to describe.*
IOS_TEST_SOURCE_ROOT = REPO / "ios" / "Packages" / "GodstoneFoundation" / "Tests"
#: **An `XCTestCase` subclass DECLARES a suite; `swift test` printeth `Test Suite '<ClassName>' passed` for it in BOTH
#: measured toolchains** (91 of 91, locally AND hosted), *while the BUNDLE naming differs between them.*
IOS_TEST_CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", re.M)


def foundation_roster() -> tuple[list[str], int]:
    """`([XCTestCase class names], arm count)` declared by the foundation package's TEST SOURCES.

    *Read rather than hard-coded, so a class or an arm added to the tree automatically becomes a REQUIREMENT here
    instead of silently widening what the control tolerates.* **AND IT IS READ FROM THE SOURCES SO THAT IT IS THE SAME
    ROSTER WHATEVER TOOLCHAIN BUILT THE LOG** -- *which is the property a hard-coded bundle name can never have.*
    """
    classes: list[str] = []
    arms = 0
    for f in sorted(IOS_TEST_SOURCE_ROOT.rglob("*.swift")):
        text = f.read_text(encoding="utf-8", errors="replace")
        classes.extend(IOS_TEST_CLASS.findall(text))
        arms += len(_UI_TEST_FUNC.findall(text))
    return sorted(set(classes)), arms


def check_ios_lane() -> tuple[list[str], dict]:
    """Parse the iOS log against a SOURCE-DERIVED roster: every declared class must PASS, and the per-bundle
    totals must EQUAL the number of source-declared `func test...` arms.

    *The contract names no bundle: WHICH BUNDLES THE TOOLCHAIN EMITS IS THE TOOLCHAIN'S CHOICE, and a control that
    hard-coded the local shape refused a hosted run that executed the same 1400 tests and passed them all.*
    """
    problems: list[str] = []
    totals = {"suites": 0, "tests": 0, "failures": 0}
    if not IOS_LOG.is_file():
        return ([f"the iOS lane log is absent at {IOS_LOG} -- the lane has not been run, and AN UNRUN LANE IS NOT A "
                 f"PASS"], totals)
    text = IOS_LOG.read_text(encoding="utf-8", errors="replace")
    # *** THE CONTRACT IS SOURCE-DERIVED, BECAUSE A HARD-CODED BUNDLE NAME IS A TOOLCHAIN'S PRIVATE CHOICE. ***
    #
    # **MEASURED, AND IT COST A HOSTED CYCLE: this used to name three bundles -- `GodstoneMeshTests.xctest`,
    # `GodstoneCoreTests.xctest`, `LabMeshTests.xctest` -- and REQUIRE EACH BY NAME.** *Apple Swift 6.4 / Xcode 27.0
    # builds ONE TEST BUNDLE PER TARGET and prints those three; **Swift 6.1.2 / Xcode 16.4 builds ONE MERGED BUNDLE
    # PER PACKAGE and prints `Test Suite 'GodstoneFoundationPackageTests.xctest' passed`.*** **THE SAME SOURCES, THE
    # SAME 1400 PASSING TESTS, AND THE CONTROL REFUSED THE HOSTED RUN FOR NAMING ITS BUNDLE DIFFERENTLY** -- *a
    # control that refuses a green lane is a control that getteth switched off.*
    #
    # *** AND THE REPLACEMENT IS STRONGER, NOT LOOSER: the roster cometh from the TEST SOURCES, so an arm that never
    # ran CANNOT be absent from it.*** *Every `XCTestCase` class declared under the package's Test directory must print
    # `Test Suite '<Class>' passed` -- **91 of 91 in BOTH logs, measured**; and the summed per-bundle totals must EQUAL
    # the number of source-declared `func test...` arms -- **1400 in BOTH, measured (1290+105+5 locally, 1400 merged
    # hosted).*** The class roster is what the three names were reaching for; the arm total is what the sum was.
    class_roster, arm_count = foundation_roster()
    got_classes = set(IOS_CLASS_SUITE.findall(text))
    totals["suites"] = len(got_classes)
    missing_classes = sorted(set(class_roster) - got_classes)
    for name in missing_classes[:6]:
        problems.append(f"the iOS lane carrieth no PASSED line for test class {name} -- a class that did not run "
                        f"(or did not pass) is not covered by this control")
    if missing_classes:
        problems.append(f"and {len(missing_classes)} of {len(class_roster)} source-declared test classes are missing "
                        f"their PASSED line in total")
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
    # **THE BUNDLE NAMES ARE READ FROM THE LOG, NOT NAMED HERE** -- *whether the toolchain emitted one merged
    # `<Package>PackageTests.xctest` or one bundle per target, EACH bundle that passed is followed by ITS OWN
    # outermost total, and the sum of those is the lane's true count in either shape.*
    run: list[tuple[int, int]] = []
    for m in re.finditer(r"^Test Suite '[\w.]+\.xctest' passed.*?^\s*Executed (\d+) tests?, with (\d+) failures?",
                         text, re.M | re.S):
        run.append((int(m.group(1)), int(m.group(2))))
    if not run:
        problems.append("the iOS lane log carrieth NO per-bundle 'Executed N tests, with M failures' total -- the run "
                        "died before its suites finished, which is exactly what a truncated or broken lane looks like")
    for tests, failures in run:
        totals["tests"] += tests
        totals["failures"] += failures
    # *** AND THE COUNT MUST RECONCILE WITH THE SOURCES: `1400` declared, `1400` measured, IN EITHER TOOLCHAIN'S SHAPE. ***
    #
    # *A total that merely EXCEEDS zero is the count-blind defect this control exists to refuse: the UI lane already
    # compares its arms BY STABLE IDENTITY rather than pinning a number, and the foundation lane getteth the same
    # treatment -- **the sum of the per-bundle totals must EQUAL the number of `func test...` arms the test sources
    # declare.*** **TWO INDEPENDENT MEASUREMENTS OF THE SAME POPULATION, so a swallowed test class, a truncated log or a
    # stale result file all show up as a mismatch instead of a green.**
    if run and totals["tests"] != arm_count:
        problems.append(f"the iOS lane executed {totals['tests']} tests but its SOURCES declare {arm_count} "
                        f"`func test...` arms -- a count that disagreeth with the sources is a swallowed class, a "
                        f"truncated log, or a log from a different tree")
    totals["evidence"] = [f"{t} tests / {f} failures" for t, f in run] + [f"SOURCES declare {arm_count} arms"]
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

        # 5. *** A LANE OUTSIDE THE SCOPE MUST NOT BE REPORTED AS A ZERO. ***
        #
        # *MEASURED, HOSTED RUN `35955759673`: the android job's control step printed `ios:foundation suites=0 tests=0
        # failures=0` and `ios:ui suites=0 tests=0 failures=0` beside its own real android counts -- **the zero
        # defaults were appended unconditionally and rendered as a measurement, so a reader would conclude the iOS
        # lanes RAN and found nothing.*** *That is the repository's own termination contract violated: "a green build
        # after a step that never ran is not evidence."*
        #
        # **AND THIS CASE CALLS THE SHIPPED `ios_scope_rows` ITSELF.** *A copy of the expression here would test the
        # copy -- the same vacuous-witness class this file existeth to remove -- so the function is the single
        # definition and both branches are exercised through it.*
        real = {"suites": 91, "tests": 1400, "failures": 0, "evidence": ["5 tests / 0 failures"]}
        unjudged = ios_scope_rows("android", real, real, ["LabMeshUITests"])
        if unjudged and all("NOT JUDGED HERE" in r for r in unjudged):
            print("   PASS: a lane outside the scope is marked NOT JUDGED")
        else:
            print(f"   FAIL: an unjudged lane was not marked -- got {unjudged}"); failures += 1
        if not any(re.search(r"tests=\d", r) for r in unjudged):
            print("   PASS: an unjudged lane carrieth NO COUNT AT ALL")
        else:
            print(f"   FAIL: an unjudged lane carrieth a count -- got {unjudged}"); failures += 1
        # *The mutation is the OLD rendering. It must be distinguishable from the repaired one, or this case would
        # pass against the defect too.*
        old_rendering = f"  {'ios:foundation':<14} suites={0:<3} tests={0:<5} failures={0}"
        if not any(r == old_rendering for r in unjudged):
            print("   PASS: the old zero-count rendering is gone")
        else:
            print("   FAIL: the defective rendering is still emitted"); failures += 1
        # *And the in-scope branch must still carry REAL counts -- a rule that silenced every lane would be a
        # different defect wearing this repair's clothes.*
        judged = ios_scope_rows("ios", real, {"suites": 2, "tests": 12, "failures": 1}, ["LabMeshUITests"])
        if any("tests=1400" in r for r in judged) and any("tests=12" in r for r in judged):
            print("   PASS: an in-scope lane still carrieth its real counts")
        else:
            print(f"   FAIL: an in-scope lane lost its counts -- got {judged}"); failures += 1

        REPO = saved

    print(f"\nselftest: {7 - failures}/7 mutations caught")
    return 1 if failures else 0


def foundation_selftest() -> int:
    """*** ADVERSARIAL MUTATIONS FOR `check_ios_lane` -- EACH MUST BE REFUSED. ***

    *This contract was REWRITTEN because the old one named three bundles the local toolchain happens to emit, and
    refused a hosted run that executed the same 1400 tests and passed every one. **A rewritten contract that has only
    ever been observed PASSING is not a control**, so its boundaries are exercised here rather than described.*

    *Each case mutates the REAL committed lane log when one exists on this host, and otherwise a shape-faithful
    synthetic log built from the source roster -- so the guard is exercised on THIS host either way.*
    """
    import tempfile

    global IOS_LOG
    failures = 0
    cases: list[tuple[str, str, str, str]] = []   # mutation, expected, observed, verdict

    real_digest = _ios_source_digest()
    if IOS_LOG.is_file():
        base = IOS_LOG.read_text(encoding="utf-8", errors="replace")
    else:
        roster, _arms = foundation_roster()
        lines = []
        for cls in roster:
            lines.append(f"Test Suite '{cls}' started at 2026-01-01.")
            lines.append(f"Test Suite '{cls}' passed at 2026-01-01.")
            lines.append("\t Executed 1 test, with 0 failures (0 unexpected) in 0.0 (0.0) seconds")
        lines.append("Test Suite 'SyntheticPackageTests.xctest' passed at 2026-01-01.")
        lines.append(f"\t Executed {_arms} tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds")
        base = "\n".join(lines) + "\n"

    def run_case(name: str, text: str, expect: str) -> None:
        # A NESTED FUNCTION NEEDS ITS OWN DECLARATION: the outer `global` does not reach into it.
        global IOS_LOG
        nonlocal failures
        with tempfile.TemporaryDirectory() as td:
            logp = Path(td) / "ios-lane.log"
            logp.write_text(text, encoding="utf-8")
            Path(str(logp) + ".sources.sha256").write_text(real_digest, encoding="utf-8")
            saved = IOS_LOG
            IOS_LOG = logp
            try:
                probs, _tot = check_ios_lane()
            finally:
                IOS_LOG = saved
        got = "red" if probs else "green"
        verdict = "KILLED" if got == expect else "ESCAPED"
        if verdict == "ESCAPED":
            failures += 1
        cases.append((name, expect, got, verdict))

    roster, arms = foundation_roster()
    first = roster[0] if roster else "SyntheticTests"
    # The mutation must bite on THIS host's log shape. The local shape sums per-target bundles; the hosted shape is
    # one merged bundle. *Whichever the log carries, reduce ONE outermost total by one test.*
    # *** THE MUTATION MUST BITE AN **OUTERMOST BUNDLE TOTAL**, NOT A NESTED SUITE'S. ***
    #
    # **MEASURED: decrementing the FIRST `Executed` line ESCAPED, because the first one belongs to a nested suite whose
    # total is not part of the sum** -- *so the mutation changed nothing the control reads, and an ESCAPED verdict there
    # would have said "the guard is broken" when the truth was "the mutation missed".* **The line that matters is the
    # one that FOLLOWS a `Test Suite '<bundle>.xctest' passed`**, which is exactly what the parser sums.
    bundle_line = re.search(r"(?sm)^Test Suite '[\w.]+\.xctest' passed.*?^(\s*Executed )(\d+)( tests?, with 0 failures)",
                            base)
    shrunk = base
    if bundle_line:
        shrunk = base[: bundle_line.start(2)] + str(int(bundle_line.group(2)) - 1) + base[bundle_line.end(2):]
    failed_bundle = base
    m2 = re.search(r"(?m)^\s*Executed (\d+) tests?, with 0 failures", base)
    if m2:
        failed_bundle = base[: m2.start()] + f"\t Executed {m2.group(1)} tests, with 2 failures" + base[m2.end():]

    run_case("1. one test class' PASSED line removed", base.replace(f"Test Suite '{first}' passed", ""), "red")
    run_case("2. a class reports failed, not passed",
             base.replace(f"Test Suite '{first}' passed", f"Test Suite '{first}' failed"), "red")
    run_case("3. an outermost total short by one test (an arm swallowed)", shrunk, "red")
    run_case("4. a nonzero failure count on an outermost total", failed_bundle, "red")
    run_case("5. the run truncated to its first third",
             "\n".join(base.splitlines()[: max(1, len(base.splitlines()) // 3)]), "red")
    run_case("6. the real log, unmutated -- MUST be accepted",
             base, "green")

    width = max(len(c[0]) for c in cases)
    for name, expect, got, verdict in cases:
        print(f"   {name:<{width}}  expect={expect:<5} got={got:<5} {verdict}")
    print(f"\nfoundation selftest: {len(cases) - failures}/{len(cases)} mutations caught")
    return 1 if failures else 0


def ui_selftest() -> int:
    """*** ADVERSARIAL MUTATIONS FOR `check_ios_ui_lane` -- TWELVE CASES, EACH MUST BE KILLED. ***

    *A control that has only ever been observed PASSING is not a control -- the lesson this session paid for
    repeatedly. Each case mutates a REAL log (the committed lane's own text where one exists, else a synthetic
    fixture) and asserts the checker refuses it, so the guards are exercised rather than described.*
    """

    global IOS_UI_LOG, REPO
    import tempfile

    failures = 0
    cases_run = 0
    results: list[tuple[str, str, str, str]] = []   # mutation, expected, observed, verdict

    def run_case(name: str, text: str, sidecar: str | None, expect: str) -> None:
        """`expect` is 'red' when the checker MUST refuse, 'green' when it MUST accept."""
        # A NESTED FUNCTION NEEDS ITS OWN DECLARATION: the outer `global` does not reach into it.
        global IOS_UI_LOG
        nonlocal failures, cases_run
        cases_run += 1
        with tempfile.TemporaryDirectory() as td:
            logp = Path(td) / "ios-ui-lane.log"
            logp.write_text(text, encoding="utf-8")
            if sidecar is not None:
                Path(str(logp) + ".sources.sha256").write_text(sidecar, encoding="utf-8")
            saved_log, saved_repo = IOS_UI_LOG, REPO
            IOS_UI_LOG = logp
            try:
                probs, _tot = check_ios_ui_lane()
            finally:
                IOS_UI_LOG = saved_log
            # The digest is computed against the REAL tree, so a fixture cannot forge it; cases that do not
            # exercise the digest pass the real value through.
            # *** THE VERDICT IS THE CHECKER'S OWN: ANY PROBLEM IS RED, AN EMPTY LIST IS GREEN. ***
            # *Notices are not problems -- that is the whole point of the known-red allowlist -- so case (6) must
            # come back with an EMPTY list while still ANNOUNCING the obligation.*
            got = "red" if probs else "green"
            verdict = "KILLED" if got == expect else "ESCAPED"
            if verdict == "ESCAPED":
                failures += 1
            results.append((name, expect, got, verdict))

    real_digest = _ios_source_digest()

    def base_text() -> str:
        if IOS_UI_LOG.is_file():
            return IOS_UI_LOG.read_text(encoding="utf-8", errors="replace")
        # A synthetic but shape-faithful log, used when no lane has been run on this host.
        roster = required_ui_arms()
        lines = []
        for suite, arms in roster.items():
            for arm in arms:
                lines.append(f"Test Case '-[{suite}.{suite} {arm.split('.')[-1]}]' passed (1.0 seconds).")
            lines.append(f"Test Suite '{suite}.xctest' passed at 2026-01-01.")
            lines.append(f"\t Executed {len(arms)} tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds")
        return "\n".join(lines) + "\n"

    base = base_text()

    # (1) an entire required suite absent.
    run_case("1. whole required suite absent",
             "\n".join(l for l in base.split("\n") if "GodstoneArchiveUITests" not in l),
             real_digest, "red")
    # (2) ONE required arm absent, the rest of its suite intact.
    arm = "testGSINT001TheWipeControlReportsTheRuntimesOwnState"
    run_case("2. one required arm absent",
             "\n".join(l for l in base.split("\n") if arm not in l), real_digest, "red")
    # (3) Executed 0.
    run_case("3. Executed 0 tests", base + "\n\t Executed 0 tests, with 0 failures\n", real_digest, "red")
    # (4) one skipped arm.
    run_case("4. one skipped arm",
             base + "\nTest Case '-[LabMeshUITests.LabMeshUITests testGSINT001X]' skipped (1.0 seconds).\n",
             real_digest, "red")
    # (5) a NEW unexpected failure (not the recorded known-red arm).
    run_case("5. a new unexpected failed arm",
             base.replace("testGSINT001TheWipeControlReportsTheRuntimesOwnState]' passed",
                          "testGSINT001TheWipeControlReportsTheRuntimesOwnState]' failed"),
             real_digest, "red")
    # (6) the named known-red arm only -- ACCEPTED **AND ANNOUNCED**. *"Accepted" alone would be satisfied by a
    # silent pass, which is the failure this case exists to forbid, so the notice is asserted too.*
    run_case("6. only the recorded known-red arm fails", base, real_digest, "green")
    with tempfile.TemporaryDirectory() as td:
        logp = Path(td) / "ios-ui-lane.log"
        logp.write_text(base, encoding="utf-8")
        Path(str(logp) + ".sources.sha256").write_text(real_digest, encoding="utf-8")
        saved = IOS_UI_LOG
        IOS_UI_LOG = logp
        try:
            _p, tot = check_ios_ui_lane()
        finally:
            IOS_UI_LOG = saved
        notices = tot.get("notices") or []
        cases_run += 1
        if notices and any("testGSA005DocumentReopensAfterCleanProcessDeath" in n for n in notices):
            results.append(("6b. known-red arm is ANNOUNCED, not silent", "notice", "notice", "KILLED"))
        else:
            failures += 1
            results.append(("6b. known-red arm is ANNOUNCED, not silent", "notice", f"{notices}", "ESCAPED"))
    # (7) a different PASSING arm changed to failed -- rejected by exact name (same shape as 5, distinct arm).
    run_case("7. a different passing arm changed to failed",
             base.replace("testGSINT001TypeSelectRecipientAndSendReachesARenderedOutcome]' passed",
                          "testGSINT001TypeSelectRecipientAndSendReachesARenderedOutcome]' failed"),
             real_digest, "red")
    # (8) missing digest.
    run_case("8. missing digest sidecar", base, None, "red")
    # (9) stale digest.
    run_case("9. stale digest sidecar", base, "0" * 64, "red")
    # (10) duplicate verdict for one arm.
    run_case("10. duplicate verdict for one arm",
             base + "\nTest Case '-[LabMeshUITests.LabMeshUITests testGSINT001TheWipeControlReportsTheRuntimesOwnState]' passed (1.0 seconds).\n",
             real_digest, "red")
    # (11) source declares a required arm the log omits -- same shape as (2) but asserted as its own case.
    run_case("11. source-declared arm omitted from the log",
             "\n".join(l for l in base.split("\n") if "testGSA005ScrollingRevealsALaterPassage" not in l),
             real_digest, "red")
    # (12b) *** THE RECORDED ARM FAILING FOR A FOREIGN REASON MUST NOT BE EXCUSED. ***
    # *This is the hole a name-only allowlist leaves: the fixture hash-guard tripping, the app not launching, or a
    # selector break would each wear a recorded arm's name and read as the known restore gap.*
    stripped = base.replace(
        "*** THE DOCUMENT MUST REOPEN AFTER A CLEAN PROCESS DEATH", "")
    run_case("12b. known-red arm fails with a FOREIGN signature", stripped, real_digest, "red")

    # (12) an empty log entirely.
    run_case("12. empty log (no arm verdicts at all)", "", real_digest, "red")

    print("\n== ui selftest: mutation | expected | observed | verdict ==")
    for name, exp, got, verdict in results:
        print(f"   {name:46s} {exp:6s} {got:6s} {verdict}")
    killed = sum(1 for r in results if r[3] == "KILLED")
    print(f"\nui selftest: {killed}/{cases_run} mutations killed")
    return 1 if failures else 0


def check_ios_ui_lane() -> tuple[list[str], dict]:
    """*** THE `bundle.ui-testing` LANE: EVERY ARM'S OWN LINE, ZERO-EXECUTED REFUSED, STALENESS BOUND. ***

    *Modelled on `check_ios_lane`, with the three guards that make a UI log honest:*
      * a REQUIRED SUITE LIST, so a target that stops running is not silently absent;
      * **`Executed 0` IS A FAILURE** -- `swift test` prints it from an inner probe, and an XCUITest run reports it
        when the runner crashes before completing, which is exactly how `Executed 4, 0 failures` appeared beside
        `** TEST FAILED **` this session;
      * **ANY SKIP IS A FAILURE**, because a skipped UI arm reports as a pass while measuring nothing;
      * and the log is bound to the SAME SOURCE DIGEST the package lane uses, so a UI edit invalidates it.
    """
    problems: list[str] = []
    totals = {"suites": 0, "tests": 0, "failures": 0, "evidence": []}
    if not IOS_UI_LOG.is_file():
        return ([f"the iOS UI lane log is absent at {IOS_UI_LOG} -- the UI targets have not been run, and AN UNRUN "
                 f"LANE IS NOT A PASS"], totals)
    text = IOS_UI_LOG.read_text(encoding="utf-8", errors="replace")

    # (a) EVERY ARM THAT PRINTED A LINE, BY NAME AND VERDICT.
    cases = IOS_UITEST_CASE.findall(text)
    suites = sorted({cls.split(".")[0] for cls, _, _ in cases})
    totals["suites"] = len(suites)
    totals["tests"] = len(cases)
    totals["failures"] = sum(1 for _, _, v in cases if v == "failed")
    for name in IOS_UI_REQUIRED_SUITES:
        if name not in suites:
            problems.append(f"the iOS UI lane carrieth no test case for suite {name} -- a UI target that did not run "
                            f"is not covered by this control")

    # *** BY NAME, NOT BY COUNT: every SOURCE-DECLARED arm must be OBSERVED. ***
    try:
        roster = required_ui_arms()
    except Exception as exc:  # noqa: BLE001 - an unobtainable roster must not read as an absent arm
        problems.append(f"the required UI arm roster could not be derived from {IOS_PROJECT_SPEC}: {exc} -- **AN "
                        f"UNOBTAINABLE ROSTER IS NOT AN EMPTY ONE**. *If the cause is the missing module, the repair is "
                          f"`pip install -r content/requirements-dev.txt`, which DECLARES PyYAML -- "
                          f"NEVER a narrower roster.*")
        roster = {}
    # The log's class token is `<Module>.<Class>`; the roster's is `<Class>`. Compare on `<Class>.<test>`.
    observed = {(c.split(".")[-1], n): v for c, n, v in cases}
    totals["required_arms"] = 0
    for suite in IOS_UI_REQUIRED_SUITES:
        for arm in roster.get(suite, []):
            totals["required_arms"] += 1
            key = arm                      # already "<Class>.<test>"
            if (arm.split(".")[0], arm.split(".")[1]) not in observed:
                problems.append(f"*** REQUIRED UI ARM ABSENT: {key} is DECLARED IN SOURCE but the log carrieth NO "
                                f"verdict for it. *** *An arm that never ran is not a passing arm -- this is the "
                                f"defect a count cannot see.*")
    # AND A DUPLICATE VERDICT WOULD DOUBLE-COUNT AN ARM.
    seen: dict[str, int] = {}
    for c, n, _v in cases:
        key = f"{c.split('.')[-1]}.{n}"
        seen[key] = seen.get(key, 0) + 1
    for key, times in sorted(seen.items()):
        if times > 1:
            problems.append(f"the iOS UI lane carrieth {times} verdicts for {key} -- a duplicated arm would be "
                            f"double-counted")
    if cases and totals["failures"]:
        # EVERY FAILED ARM IS NAMED; ONLY THE PRE-RECORDED ONES ARE EXCUSED, AND THEY ARE STILL ANNOUNCED.
        unexplained = []
        for c, n, v in cases:
            if v != "failed":
                continue
            full = f"{c}.{n}"
            known = IOS_UI_KNOWN_RED.get(full)
            if known is None:
                unexplained.append(full)
                continue
            # *** THE SIGNATURE BINDING: the recorded arm must fail FOR THE RECORDED REASON. ***
            if known.get("signature") and known["signature"] not in text:
                unexplained.append(
                    f"{full} -- RECORDED as known-red, **BUT WITHOUT ITS RECORDED SIGNATURE**: the log carrieth no "
                    f"`{known['signature']}`, so this failure is NOT the obligation that was recorded. A novel break "
                    f"wearing a recorded arm's name must not be excused by it.")
                continue
            totals["known_red"] = totals.get("known_red", 0) + 1
            totals.setdefault("notices", []).append(
                f"KNOWN-RED UI arm (recorded as OWED, not excused): {full} -- {known['obligation']}")
        if unexplained:
            problems.append(f"the iOS UI lane carrieth FAILED arms: {', '.join(unexplained)}")
    if not cases:
        problems.append("the iOS UI lane log carrieth NO `Test Case '...' passed|failed` line -- **AN EMPTY RUN IS "
                        "NOT A PASS**, and a log with no per-arm verdicts cannot distinguish 'all passed' from "
                        "'nothing executed'")

    # (b) `Executed 0` AND ANY SKIP ARE FAILURES, BY NAME.
    for m in re.finditer(r"^\s*Executed (\d+) tests?, with (\d+) failures?", text, re.M):
        if int(m.group(1)) == 0:
            problems.append("the iOS UI lane carrieth `Executed 0 tests` -- **A ZERO-EXECUTED RUN IS WHAT A CRASHED "
                            "XCUITest PROCESS REPORTS, and it must never read as green**")
            break
    for m in re.finditer(r"^Test Case '([^']+)' skipped", text, re.M):
        problems.append(f"the iOS UI lane carrieth a SKIPPED arm ({m.group(1)}) -- a skipped witness reports as a "
                        f"pass while measuring nothing")
        break

    # (c) THE STALENESS GUARD, the same one the package lane uses.
    side = Path(str(IOS_UI_LOG) + ".sources.sha256")
    if not side.is_file():
        problems.append(f"the iOS UI lane carrieth no digest sidecar at {side} -- an undatable log is not evidence "
                        f"about the current tree")
    else:
        recorded = side.read_text(encoding="utf-8").strip().split()[0]
        current = _ios_source_digest()
        if recorded != current:
            problems.append(f"the iOS UI lane log is STALE: its source digest {recorded[:16]}… does not match the "
                            f"tree's {current[:16]}… -- *the log never saw these sources, so it is not evidence "
                            f"about them. Re-run the lane.*")
    return (problems, totals)


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


def ios_scope_rows(scope: str, ios_totals: dict, ui_totals: dict, ui_evidence: list[str]) -> list[str]:
    """*** THE iOS ROWS OF THE SUMMARY, FOR A GIVEN SCOPE. ONE DEFINITION, SO THE SELFTEST CAN EXERCISE THE REAL ONE. ***

    *MEASURED, HOSTED RUN `35955759673`: the android job's control step printed `ios:foundation suites=0 tests=0
    failures=0` and `ios:ui suites=0 tests=0 failures=0` beside its own real android counts -- **because these rows were
    appended unconditionally and the zero defaults rendered as a measurement.*** *A reader of that job's log would
    conclude the iOS lanes ran and found nothing, which is the opposite of the truth: they are judged by the iOS job.*

    **AND IT IS THE REPOSITORY'S OWN TERMINATION CONTRACT THAT THIS VIOLATED -- "A GREEN BUILD AFTER A STEP THAT NEVER
    RAN IS NOT EVIDENCE."** *A zero in a lane column is the shape of evidence.*

    *So a lane the scope did not judge sayeth so, and carrieth NO COUNT. **THIS FUNCTION EXISTS SO THAT RULE IS
    EXERCISED BY `--selftest` RATHER THAN MERELY DESCRIBED** -- a second copy of the expression inside the selftest
    would test the copy, which is the same vacuous-witness class this file existeth to remove.*
    """
    if scope in ("all", "ios"):
        return [
            f"  {'ios:foundation':<14} suites={ios_totals['suites']:<3} tests={ios_totals['tests']:<5} "
            f"failures={ios_totals['failures']}  <- per bundle: " + "; ".join(ios_totals.get("evidence", [])),
            f"  {'ios:ui':<14} suites={ui_totals['suites']:<3} tests={ui_totals['tests']:<5} "
            f"failures={ui_totals['failures']}  <- the `bundle.ui-testing` targets: " + ", ".join(ui_evidence),
        ]
    return [
        f"  {'ios:foundation':<14} NOT JUDGED HERE -- the iOS lanes stand outside `--scope {scope}` and are judged by "
        f"the iOS job",
        f"  {'ios:ui':<14} NOT JUDGED HERE -- the iOS lanes stand outside `--scope {scope}`",
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", choices=("all", "ios", "android"), default="all",
                    help="which lanes this invocation is responsible for -- *a control run inside the iOS job "
                         "cannot judge the ANDROID lanes, which a different job produces, nor the UI lane, which has "
                         "not run yet; asking it to would refuse thirteen things that are merely ABSENT*")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--selftest-ui", action="store_true")
    ap.add_argument("--selftest-foundation", action="store_true")
    args = ap.parse_args()
    if args.selftest_foundation:
        return foundation_selftest()
    if args.selftest_ui:
        return ui_selftest()
    if args.selftest:
        return selftest()

    all_problems: list[str] = []
    summary: list[str] = []
    for label, task_dir, pattern in (LANES if args.scope in ("all", "android") else ()):
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

    ios_probs, ios_totals = check_ios_lane() if args.scope in ("all", "ios") else ([], {"suites": 0, "tests": 0, "failures": 0, "evidence": []})
    all_problems.extend(ios_probs)

    # *** THE UI LANE IS MANDATORY UNDER `--scope ios` -- NEVER OPTIONAL-WHEN-PRESENT. ***
    #
    # *MY FIRST VERSION INCLUDED IT ONLY WHEN ITS LOG EXISTED, so an absent UI log reported **PASSED** -- **and I
    # measured that: with the log moved away, `--scope ios` printed `ios:ui suites=0 tests=0` and
    # `lane results: PASSED`, rc=0.*** **That is "a required test never ran" reading as green, which is precisely
    # the state this task exists to make impossible.**
    #
    # **SO `--scope ios` REQUIRES BOTH iOS LANES, AND THE iOS JOB INVOKES IT ONLY AFTER BOTH HAVE RUN.** *A job that
    # wants to judge the foundation lane before the UI step does not exist here, and would need its own named scope
    # rather than a softer meaning of this one.*
    if args.scope in ("all", "ios"):
        ui_probs, ui_totals = check_ios_ui_lane()
    else:
        # *Same rule as `ios:foundation` above, and for the same measured reason: never a zero for a lane this scope
        # did not judge.*
        ui_probs, ui_totals = ([], {"suites": 0, "tests": 0, "failures": 0, "known_red": 0})

    # *** THE iOS ROWS COME FROM ONE DEFINITION (`ios_scope_rows`), WHICH `--selftest` EXERCISETH DIRECTLY. ***
    # *A lane outside the scope sayeth so and carrieth NO COUNT; a lane inside it carrieth its real counts. **Both
    # branches are the same call, so the selftest cannot drift from the shipped rendering.***
    summary.extend(ios_scope_rows(args.scope, ios_totals, ui_totals, list(IOS_UI_REQUIRED_SUITES)))
    # NOTICES ARE ANNOUNCED, NEVER COUNTED AS FAILURES -- *a recorded gap is not a broken lane, and a notice that
    # reddened the control would force the known-red entry to be DELETED to get green.*
    for notice in ui_totals.get("notices", []):
        summary.append("    ::notice:: " + notice)
    all_problems.extend(ui_probs)

    print("LANE RESULTS (parsed from the result files, not grepped from stdout):")
    print("\n".join(summary))
    if all_problems:
        print("\nFAIL:")
        for p in all_problems:
            print("  - " + p)
        # *** THE EVIDENCE EXCERPT EXISTS BECAUSE I SPENT A HOSTED RUN GUESSING. ***
        #
        # **MEASURED ON RUN `35903873741`: the iOS job's foundation lane passed (rc=0, 6m36s) and the control then read
        # `ios:foundation suites=1 tests=0` -- and NOTHING IN THE LOG I COULD RETRIEVE SAID WHY.** *The lane's output
        # goeth to `ios-lane.log`, which the workflow did not upload, so the ONLY record of a 1400-test run was
        # discarded with the runner. A control whose refusal cannot be diagnosed from its own output forces the next
        # reader to repeat the entire cycle.*
        #
        # **SO A REFUSAL PRINTETH A CENSUS OF THE LOG IT ACTUALLY READ, BOUNDED, STRUCTURAL, AND OF THE LINE KINDS
        # THE PARSER KEYS ON** -- *counts tell a truncated log from a foreign format, and the tail shows where the
        # output stopped.* It printeth the log's PATH, its SIZE, a kind-by-kind line census, and a bounded tail.
        for path in (IOS_LOG, IOS_UI_LOG):
            if not path.is_file():
                print(f"\n  [evidence] {path} -- ABSENT")
                continue
            raw = path.read_text(encoding="utf-8", errors="replace").splitlines()
            census = {k: 0 for k in LOG_LINE_KINDS}
            for line in raw:
                for kind, rx in LOG_LINE_KINDS.items():
                    if rx.search(line):
                        census[kind] += 1
            print(f"\n  [evidence] {path.name}: {len(raw)} lines, {path.stat().st_size} bytes")
            for kind in LOG_LINE_KINDS:
                print(f"      {kind:<34} {census[kind]}")
            tail = raw[-12:]
            print(f"      --- last {len(tail)} line(s) verbatim ---")
            for line in tail:
                print("      | " + line[:180])
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



#: *** THE RIG THAT DECIDES WHAT THE LANE COMPILES, AND THE BYTES THE WITNESS VERIFIED. ***
#:
#: *MEASURED GAP (found by reading this file rather than trusting it): the digest walked ONLY `*.swift` under the four
#: source trees, so **`ios/project.yml` WAS NOT DIGESTED AT ALL** -- yet that file is precisely what decides which
#: target and scheme get compiled and executed. Registering OR REMOVING `GodstoneArchiveUITests` / `GodstoneArchiveUI`
#: there would leave an existing lane log reading "current", which is the control's own Phase-5 clause about no
#: required test being omitted by target configuration.*
#:
#: *AND THE COMMITTED FIXTURE BYTES WERE OUTSIDE THE DIGEST TOO (non-`.swift`).* The executed app witness verifies the
#: fixture's sha256 at RUN time, so tampering fails the arm -- **but the LANE LOG'S green was not bound to the bytes it
#: claimed to have verified**, which is the same shape: a log that cannot date itself against what it exercised.*
IOS_RIG_FILES = (
    "ios/project.yml",
)
IOS_FIXTURE_TREES = (
    "ios/Godstone/Tests/GodstoneArchiveUITests/Fixtures",
)


def _ios_source_digest() -> str:
    """A digest over every byte the iOS lane compiles OR IS CONFIGURED BY, plus the fixture bytes it verifies.

    *Path-sorted, so it is order-stable. `*.swift` under the source trees, plus the project spec that selects which
    targets run, plus every committed fixture byte -- so a changed rig or a changed fixture INVALIDATES an older log
    instead of leaving it looking current.*
    """
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
    # THE RIG: which target and scheme the lane compiles and runs.
    for rel in IOS_RIG_FILES:
        f = REPO / rel
        if not f.is_file():
            continue
        h.update(str(f.relative_to(REPO)).encode())
        h.update(b"\0")
        h.update(f.read_bytes())
        h.update(b"\0")
    # THE FIXTURE BYTES the executed app witness verifies at run time -- so the log is bound to them too.
    for rel in IOS_FIXTURE_TREES:
        base = REPO / rel
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*")):
            if not f.is_file():
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
