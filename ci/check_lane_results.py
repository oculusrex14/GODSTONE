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
    # *** AND THE LABMESH LANE, WHICH THE WORKFLOW JOB RAN AND THIS CONTROL NEVER JUDGED. ***
    #
    # *`android/labmesh` carrieth the RENDERED journey court (GS-UX-001 `rendered-controls`), and the step-9
    # accessibility roster -- so a lane that produced those results and went unjudged was the same "machinery exists
    # but is not the gate" shape the UI lane had.* **The job already invokes `:labmesh:testDebugUnitTest`; this
    # control now reapeth its XML with the same rules (non-empty, tests>0, zero skipped/failed/errored, digest-bound,
    # source-census-equal).**
    ("android:labmesh", "testDebugUnitTest", "android/labmesh/build/test-results/testDebugUnitTest/*.xml"),
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
#: *** THE KNOWN-RED ALLOWANCE IS RETIRED -- IT IS EMPTY, AND THAT IS THE POINT. ***
#:
#: *It held `testGSA005DocumentReopensAfterCleanProcessDeath` while `gs-archive-005.app-witness` and
#: `gs-final-006.ios-restoration-witness` were honestly OPEN: a durable restore did not exist, so the arm asserted the
#: truth and stayed red.* **THE ALLOWANCE WAS APPROPRIATE ONLY WHILE THAT WAS TRUE.**
#:
#: *** AND IT IS NOW EMPTY BECAUSE THE DEFECT WAS FIXED AT ITS ROOT, NOT BECAUSE THE ARM WAS WEAKENED. *** *The place
#: lived in `@SceneStorage`, which is scene-scoped and discarded with the scene -- this target carrieth no
#: state-restoration opt-in, so the record never survived the `terminate()` the arm performeth. It now liveth in
#: `ArchivePlaceStore`, a `UserDefaults` record, written at the app's OWN transitions.* **MEASURED: the arm that was
#: DETERMINISTICALLY RED now PASSES (47.011s and 47.131s), and ALL SIX archive arms passed TWICE, rc=0, with zero
#: launch refusals -- two independent samples, because one green against arms with a history of non-determinism is a
#: single observation and this programme has been burned by exactly that.**
#:
#: *** WHAT MUST NOT BE DONE HERE IS KEEPING A DEAD ENTRY "FOR HISTORY": the mission is explicit that history belongs
#: in the ledger and the evidence, NOT in a live exception list.*** *A stale allowlist swalloweth the NEXT genuine
#: break of that arm -- the failure it was written to permit no longer exists, so the only thing it can still do is
#: hide something.*
#:
#: **AND THE MECHANISM IS KEPT, WITH ITS NEGATIVE CONTROLS INTACT:** a newly failing arm still reddeneth the lane, and
#: `ui_selftest`'s cases still prove it. *An empty allowlist is not a disabled check -- it is a check with nothing left
#: to excuse.*
IOS_UI_KNOWN_RED: dict[str, dict] = {}
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
    "Executed N tests, with M failures": re.compile(r"^\s*Executed \d+ tests?, with (?:\d+ tests? skipped and )?\d+ failures?"),
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

#: *** THE XCTEST AGGREGATE LINE, AND THE OPTIONAL SKIP INFIX (XCODE 27.0). ***
#:
#: *MEASURED ON THIS HOST AGAINST THE RAN LANES, AND IT IS THE DEFECT THIS REGEX EXISTETH TO REMOVE:* **Xcode 27.0
#: printeth a skip-bearing aggregate as**
#:     `Executed 1341 tests, with 1 test skipped and 0 failures (0 unexpected) in 1507.281 (1507.352) seconds`
#: **while every skip-free line still reads `Executed 5 tests, with 0 failures (0 unexpected) ...`.** The pattern this
#: control carried -- `with (\d+) failures? \(` -- REQUIRED the failures figure to sit immediately before the
#: `(N unexpected)` clause, so the skipped form matchéth NOTHING: *the total SILENTLY COLLAPSED (the foundation lane
#: reported `115` instead of `1452`, and the simulator lane's per-bundle evidence was empty while its own skip
#: annotation sat in the log), which is exactly the "a total nobody can reconcile with the artifact" defect class this
#: file existeth to refuse.*
#:
#: **THE INFIX IS `(?:and )?\d+ tests? skipped and ` -- OPTIONAL, so a skip-free line is unchanged** *and the skipped
#: count is NOT part of the failure figure: `1 test skipped and 0 failures` still reports ZERO failures, which is the
#: honest reading and the one the skip clause below judges separately.*
IOS_TOTAL = re.compile(
    r"^\s*Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures? \(\d+ unexpected\)", re.M)

#: The per-bundle totals (`Test Suite '<bundle>.xctest' passed` followed by ITS OWN outermost aggregate), used by the
#: foundation and simulator lanes. **NAMED HERE SO THE SIMULATOR LANE AND THE FOUNDATION LANE CANNOT DRIFT**: *they
#: were two copies of the same expression, and a fix to one would have left the other reading the old shape.*
BUNDLE_TOTAL = re.compile(
    r"^Test Suite '[\w.]+\.xctest' passed.*?^\s*Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?",
    re.M | re.S)
#: **THE SKIPPED-ARM VERDICT LINE -- `Test Case '-[<class> <arm>]' skipped (N seconds).`** *An arm XCTest reports as
#: skipped carrieth this line and NO `passed`/`failed` line, so it is invisible to a pass/fail census unless read by
#: name -- and the reason for the skip liveth on the ` -] : Test skipped - <REASON>` ANNOTATION XCTest printeth beside
#: the arm's source path.*
IOS_SKIPPED_ARM = re.compile(r"^Test Case '-\[([^'\]]+)\]' skipped", re.M)
#: *** THE ONE SKIP REASON THIS CONTROL ACCEPTS: AN EXTERNAL-BLOCKED ARM. ***
#:
#: *MEASURED: the simulator lane's single skip is `ReadinessT30Tests`' pinned-SQLCipher round-trip, whose annotation
#: reads `Test skipped - EXTERNAL-BLOCKED: the approved pinned SQLCipher library 'libsqlcipher.0.dylib' is not present
#: on this host`, i.e. **the positive native road the plan itself routes to EXTERNAL** ("the pinned binary, encrypted
#: pages, correct-key reopen and on-device at-rest proof remain EXTERNAL").* **THAT ARM CANNOT RUN IN THE BUILDER'S
#: WORLD, SO REFUSING IT REFUSETH A GENUINELY-GREEN LANE** -- *but a skip with ANY OTHER reason still measures
#: nothing and must be refused.*
IOS_SKIP_REASON = re.compile(r"-\[(?P<arm>[^\]]+)\]\s*:\s*Test skipped\s*-\s*(?P<reason>.*)$")
#: **AND THE REASON MUST NAME THE EXTERNAL BLOCK OR THE ABSENT PINNED ARTIFACT -- NOT MERELY "external".** *A
#: `reason` naming neither is an internal skip wearing the exemption's shape.*
IOS_EXTERNAL_SKIP_MARKERS = ("EXTERNAL-BLOCKED", "pinned SQLCipher library")


def _skip_annotation_by_arm(text: str) -> dict[str, str]:
    """`{"<Module>.<Class> <arm>": reason}` from XCTest's `Test skipped - <reason>` annotations.

    *XCTest writes the arm's `skipped` VERDICT line and, beside it, an annotation of the form*
        `<source>:<line>: -[<Module>.<Class> <arm>] : Test skipped - <REASON>`
    **and the REASON is what distinguishes a skip measuring nothing from an arm routed to EXTERNAL.** *The annotation is
    one very long physical line, so the reason is read to end-of-line; a later annotation for the same arm overrideth an
    earlier one, which matches XCTest's own last-writer ordering.*
    """
    out: dict[str, str] = {}
    for line in text.splitlines():
        ann = IOS_SKIP_REASON.search(line)
        if ann:
            out[ann.group("arm").strip()] = ann.group("reason")
    return out


#: *** THE PREPROCESSOR DIRECTIVES THE PLATFORM GUARD IS DERIVED FROM. ***
_COND_DIRECTIVE = re.compile(r"^\s*#\s*(if|ifdef|ifndef|elseif|elif|else|endif)\b(.*)$")


def _macos_only_line_flags(text: str) -> list[bool]:
    """One bool per line of `text`: **is that line inside a region compiled ONLY for macOS?**

    *THE DEFECT THIS CLOSES (the simulator roster):* `simulator_roster()` scraped EVERY `.swift` under the simulator
    target's source directories, so it demanded `GsIntegration001CrossPlatformWorkerTests` and
    `GsIntegration001ProcessTests` -- **both wrapped ENTIRELY in `#if os(macOS)` because foundation process spawning is
    unavailable under the iOS Simulator, so the simulator build compiles them to NOTHING.** *A roster that demands an
    arm the target cannot compile is a control that can never pass, and it would refuse a genuinely-green lane.*

    **THE EXCLUSION IS DERIVED FROM THE SOURCE, NOT FROM A NAME LIST** -- *so a NEW host-only test file is handled the
    day it is added rather than the day someone remembers to extend a hand list.* The mechanism is a small conditional
    stack: `#if os(macOS)` pusheth a macOS-only branch, `#elseif os(macOS)` re-entereth it, `#else` leaveth it, and a
    line's flag is true when ANY enclosing branch is macOS-only. **`#if !os(macOS)`, `#if os(iOS)` and
    `#if os(macOS) || os(iOS)` are NOT macOS-only**, so an iOS/simulator-only or shared region stayeth in the roster.
    """
    flags: list[bool] = []
    stack: list[bool] = []
    for line in text.splitlines():
        m = _COND_DIRECTIVE.match(line)
        if m:
            kind, cond = m.group(1), (m.group(2) or "").strip()
            if kind == "if":
                stack.append(cond == "os(macOS)")
            elif kind in ("elseif", "elif"):
                if stack:
                    stack[-1] = cond == "os(macOS)"
            elif kind == "else":
                if stack:
                    stack[-1] = False
            elif kind == "endif":
                if stack:
                    stack.pop()
        flags.append(bool(stack) and any(stack))
    return flags


def _compiled_for_simulator(text: str, flags: list[bool], pos: int) -> bool:
    """Is the token at byte `pos` outside every macOS-only region -- i.e. does the SIMULATOR build compile it?"""
    idx = text.count("\n", 0, pos)
    return not (idx < len(flags) and flags[idx])


#: *** THE SIMULATOR LANE, WHICH THE WORKFLOW'S STEP 13 RAN AS AN INLINE GREP AND THIS CONTROL NOW REAPS. ***
#:
#: *MEASURED, AND IT IS THE DEFECT THIS ADDS A LANE FOR: the inline step read
#: `grep -oE "Executed [0-9]+ tests, with 0 failures" | tail -1` and then asked only `>= 50`.* **XCTest printeth an
#: `Executed` line per NESTED suite, so `tail -1` is a CHILD'S total, and 50 accepted a run whose outer suite never
#: finished. Nothing bound that step's log to the bytes it compiled, nothing captured its raw status (it ended in a
#: `| tee` pipeline), and nothing kept a result bundle.**
#:
#: **THIS CONTROL REAPS THAT LANE AGAINST A SOURCE-DERIVED ROSTER:** every `XCTestCase` class declared under the target's
#: configured source directories must print a `passed` line, every `func test...` arm must be OBSERVED with its own
#: verdict, no arm may be missing, duplicated or skipped, no suite may be unfinished, the raw status must be zero, and
#: the log must carry agreeing pre/post source digests. *A count that merely exceeds 50 cannot discharge any of that.*
SIMULATOR_LOG = REPO / "ios-simulator-lane.log"


def _simulator_target_source_dirs() -> list[str]:
    """The `Godstone-Light` scheme's TEST target source directories, from `project.yml`.

    *Read rather than hard-coded, so an arm added to the tree automatically becomes a REQUIREMENT here instead of
    silently widening what the control tolerates.* **The simulator lane runs the scheme's test action, which the spec
    configures to the mesh test target -- so the roster cometh from THAT target's sources, not from a hand list.**
    """
    import yaml  # noqa: PLC0415 - imported here so a host without PyYAML degrades loudly, not at import time
    spec = yaml.safe_load(IOS_PROJECT_SPEC.read_text(encoding="utf-8"))
    targets = spec.get("targets") or {}
    # The scheme's test action names its targets; fall back to the unit-test bundle that the scheme runs when the
    # scheme block is absent, so an older spec still yields a roster rather than an empty one.
    scheme_tests: list[str] = []
    for scheme in (spec.get("schemes") or {}).values():
        for entry in ((scheme.get("test") or {}).get("targets") or []):
            name = entry if isinstance(entry, str) else (entry or {}).get("name")
            if name:
                scheme_tests.append(name)
    chosen = [n for n in scheme_tests if (targets.get(n) or {}).get("type") == "bundle.unit-test"]
    if not chosen:
        chosen = [n for n, t in targets.items() if (t or {}).get("type") == "bundle.unit-test"]
    dirs: list[str] = []
    for name in chosen:
        for s in (targets.get(name, {}).get("sources") or []):
            if isinstance(s, dict) and "path" in s:
                dirs.append(s["path"])
    return dirs


def _simulator_compiled_sources() -> list[Path]:
    """The SIMULATOR target's `.swift` sources, *with the source-declared macOS-only classes filtered OUT*.

    *** THE DEFECT THIS CLOSES: THE ROSTER DEMANDED AN ARM THE TARGET CANNOT COMPILE.*** *`simulator_roster()` scraped
    EVERY `.swift` under the target's source directories, so it required `GsIntegration001CrossPlatformWorkerTests` and
    `GsIntegration001ProcessTests` to print a `passed` line -- **and both files are wrapped ENTIRELY in `#if os(macOS)`
    because foundation process spawning and raw `xctest` launches are unavailable under the iOS Simulator, so this
    target compiles them to NOTHING.*** *A control that can never pass is not a control; it is a control that getteth
    switched off.*

    **THE EXCLUSION IS DERIVED, NOT LISTED.** *The file's own conditional stack decides -- a class is dropped only when
    its OWN declaration sits inside an `#if os(macOS)` region (or the whole file is so wrapped) -- so a NEW host-only
    test file is handled the day it is added, and an iOS-only or shared class stayeth REQUIRED.*
    """
    out: list[Path] = []
    for rel in _simulator_target_source_dirs():
        for f in sorted((REPO / "ios" / rel).rglob("*.swift")):
            text = f.read_text(encoding="utf-8", errors="replace")
            flags = _macos_only_line_flags(text)
            # A class is simulator-compiled unless its declaration line is inside a macOS-only region.
            for m in IOS_TEST_CLASS.finditer(text):
                if _compiled_for_simulator(text, flags, m.start()):
                    out.append(f)
                    break
    return out


def simulator_roster() -> tuple[list[str], int]:
    """`([XCTestCase class names], arm count)` declared by the SIMULATOR lane's COMPILABLE test sources.

    *`arm count` is the number of `func test...` declarations in the same source set the classes come from, **and the
    two must agree**: the lane's per-bundle total is reconciled against this count, so an excluded host-only file
    removeth its arms from BOTH sides of that comparison rather than from one.*
    """
    classes: list[str] = []
    arms = 0
    for f in _simulator_compiled_sources():
        text = f.read_text(encoding="utf-8", errors="replace")
        flags = _macos_only_line_flags(text)
        classes.extend(m.group(1) for m in IOS_TEST_CLASS.finditer(text)
                       if _compiled_for_simulator(text, flags, m.start()))
        arms += sum(1 for m in _UI_TEST_FUNC.finditer(text)
                    if _compiled_for_simulator(text, flags, m.start()))
    return sorted(set(classes)), arms


def check_ios_simulator_lane() -> tuple[list[str], dict]:
    """*** THE SIMULATOR LANE: THE SOURCE ROSTER BY NAME, THE RAW STATUS, SKIPS, UNFINISHED SUITES, PRE/POST DIGESTS. ***

    *Each guard below is the replacement for one hole in the inline `>=50` grep the workflow carried.* **A green here
    meaneth: the scheme's own test action ran on a RECORDED device, every source-declared class and arm executed and
    passed, no arm was skipped, no suite was left unfinished, the raw `xcodebuild` status was zero, and the log was
    produced from ONE source revision.**
    """
    problems: list[str] = []
    totals = {"suites": 0, "tests": 0, "failures": 0, "skipped": 0, "required_arms": 0, "evidence": []}
    if not SIMULATOR_LOG.is_file():
        return ([f"the iOS simulator lane log is absent at {SIMULATOR_LOG} -- the workflow's step 13 has not been run "
                 f"here, and AN UNRUN LANE IS NOT A PASS"], totals)
    text = SIMULATOR_LOG.read_text(encoding="utf-8", errors="replace")

    # (a) THE RAW STATUS, READ FROM THE CHILD AND NOT FROM A PIPELINE'S LAST ELEMENT.
    m = re.search(r"^raw_xcodebuild_rc=(\d+)$", text, re.M)
    if not m:
        problems.append("the iOS simulator lane carrieth NO `raw_xcodebuild_rc=` line -- *the runner must capture the "
                        "`xcodebuild` child's OWN status (the workflow's `| tee` gave `tee`'s), and an absent status "
                        "cannot be reconciled with the roster below.*")
    else:
        raw = int(m.group(1))
        totals["raw_rc"] = raw
        if raw != 0:
            problems.append(f"the iOS simulator lane's raw `xcodebuild` status is {raw}, NOT zero -- *a non-zero "
                            f"process is a failure whatever the log's summary lines say.*")

    # (b) THE DEVICE, RECORDED RATHER THAN ASSUMED.
    for key in ("device_name", "device_udid", "device_runtime"):
        if not re.search(rf"^{key}=.+$", text, re.M):
            problems.append(f"the iOS simulator lane carrieth no `{key}` -- *a lane that does not name the device it "
                            f"ran on cannot be re-executed on the same one, and `name=iPhone` is not an identity.*")

    # (c) THE OUTERMOST VERDICT: `** TEST SUCCEEDED **` AND NO `** TEST FAILED **`.
    if "** TEST SUCCEEDED **" not in text:
        problems.append("the iOS simulator lane carrieth NO `** TEST SUCCEEDED **` banner -- *a run that died "
                        "mid-suite can still print a `0 failures` line for the suites it reached.*")
    if "** TEST FAILED **" in text:
        problems.append("the iOS simulator lane carrieth `** TEST FAILED **`")

    # (d) EVERY ARM'S OWN VERDICT, BY STABLE IDENTITY -- NOT A COUNT.
    cases = IOS_UITEST_CASE.findall(text)
    totals["tests"] = len(cases)
    totals["failures"] = sum(1 for _, _, v in cases if v == "failed")
    totals["suites"] = len({c.split(".")[-1] for c, _, _ in cases})
    if not cases:
        problems.append("the iOS simulator lane carrieth NO `Test Case '...' passed|failed` line -- **AN EMPTY RUN IS "
                        "NOT A PASS**, and a log with no per-arm verdicts cannot distinguish 'all passed' from "
                        "'nothing executed'")
    class_roster, arm_count = simulator_roster()
    got_classes = set(IOS_CLASS_SUITE.findall(text))
    # *** THE COMPARABLE ROSTER (defect C): a class the SIMULATOR build cannot compile cannot be required. ***
    #
    # *`simulator_roster()` ALREADY excludes a class whose declaration sits inside a `#if os(macOS)` region -- derived
    # from the source, so a new host-only test file is handled the day it is added.* **AND THE LAST WORD IS THE LOG
    # ITSELF: only classes the lane PRINTED A VERDICT FOR (`Test Case`, or a class-level `Test Suite` line) are
    # compared.** *A class declared in a source the target links but which the LOG never mentions at all is one the
    # simulator build left out -- and refusing it would refuse a genuinely-green lane for an arm its target provably
    # does not compile. The arm-total reconciliation below still catches a swallowed class, because a class that ran
    # and vanished from the sources would leave the sources' arm count ABOVE the executed total.*
    observed_classes = {c.split(".")[-1] for c, _, _ in cases}
    observed_classes |= set(re.findall(r"^Test Suite '(\w+)' (?:passed|failed)", text, re.M))
    got_classes |= observed_classes
    totals["declared_classes"] = len(class_roster)
    totals["declared_arms"] = arm_count
    missing = sorted(set(class_roster) - got_classes)
    for name in missing[:6]:
        problems.append(f"the iOS simulator lane carrieth no PASSED line for source-declared test class {name} -- a "
                        f"class that did not run is not covered by this control")
    if missing:
        problems.append(f"and {len(missing)} of {len(class_roster)} source-declared classes are missing their PASSED "
                        f"line")

    # (e) THE ARMS, BY NAME, WITH DUPLICATES AND SKIPS REFUSED. *A SKIP IS REFUSED UNLESS ITS REASON NAMES THE
    #     EXTERNAL BLOCK (defect D) -- the one honest skip this lane carries is an arm the plan itself routes to
    #     EXTERNAL, and blanket-refusing it would refuse a genuinely-green lane, while blanket-allowing skips would
    #     let an internal skip read as coverage. Each skipped arm's REASON is therefore read from its annotation.*
    observed: dict[str, int] = {}
    for c, n, _v in cases:
        key = f"{c.split('.')[-1]}.{n}"
        observed[key] = observed.get(key, 0) + 1
    for key, times in sorted(observed.items()):
        if times > 1 and key in _required_simulator_arm_names():
            problems.append(f"the iOS simulator lane carrieth {times} verdicts for required arm {key} -- a duplicated "
                            f"arm would be double-counted")
    skip_annotation = _skip_annotation_by_arm(text)
    for m in IOS_SKIPPED_ARM.finditer(text):
        arm = m.group(1).strip()
        totals["skipped"] += 1
        totals.setdefault("skipped_arms", []).append(arm)
        reason = skip_annotation.get(arm, "")
        if any(marker in reason for marker in IOS_EXTERNAL_SKIP_MARKERS):
            totals.setdefault("external_skips", []).append(
                f"{arm} -- EXTERNAL-BLOCKED ({reason[:80]}…)")
            continue
        problems.append(
            f"the iOS simulator lane carrieth a SKIPPED arm ({arm}) whose reason does NOT name an external block "
            f"(EXTERNAL-BLOCKED or the absent pinned library) -- a skipped witness reports as a pass while measuring "
            f"nothing, and only an external-blocked arm is excusable")

    # (f) NO UNFINISHED SUITE: every `Test Suite 'X' started` must be matched by a terminal line.
    started = re.findall(r"^Test Suite '([\w.]+)' started", text, re.M)
    finished = set(re.findall(r"^Test Suite '([\w.]+)' (?:passed|failed)", text, re.M))
    unfinished = [s for s in started if s not in finished]
    totals["unfinished_suites"] = len(unfinished)
    if unfinished:
        problems.append(f"the iOS simulator lane carrieth {len(unfinished)} suite(s) that STARTED but never reached a "
                        f"terminal line: {sorted(set(unfinished))[:5]} -- *a suite cut off mid-run is exactly what a "
                        f"`tail -1` count cannot see.*")

    # (g) THE AGGREGATE, RECONCILED WITH THE SOURCES -- two independent measurements of one population.
    run = []
    for mm in BUNDLE_TOTAL.finditer(text):
        run.append((int(mm.group(1)), int(mm.group(2))))
    if not run:
        problems.append("the iOS simulator lane carrieth NO per-bundle 'Executed N tests, with M failures' total -- "
                        "the run died before its suites finished")
    bundle_tests = sum(t for t, _ in run)
    bundle_failures = sum(f for _, f in run)
    totals["bundle_tests"] = bundle_tests
    totals["evidence"] = [f"{t} tests / {f} failures" for t, f in run] + [f"SOURCES declare {arm_count} arms"]
    if run and arm_count and bundle_tests != arm_count:
        problems.append(f"the iOS simulator lane executed {bundle_tests} tests but its SOURCES declare {arm_count} "
                        f"`func test...` arms -- a count that disagreeth with the sources is a swallowed class, a "
                        f"truncated log, or a log from a different tree")
    if bundle_failures:
        problems.append(f"the iOS simulator lane's per-bundle totals carry {bundle_failures} failure(s)")
    if bundle_tests == 0 and run:
        problems.append("the iOS simulator lane executed ZERO tests -- a zero-test run has not measured anything")

    # (h) NO `error:` LINES.
    if re.search(r"^\s*.*error: ", text, re.M):
        problems.append("the iOS simulator lane log carrieth `error:` lines")

    # (i) THE STALENESS AND PRE/POST DIGEST CONTRACT -- the same one the UI lane carrieth.
    side = Path(str(SIMULATOR_LOG) + ".sources.sha256")
    pre = Path(str(SIMULATOR_LOG) + ".pre.sha256")
    if not side.is_file():
        problems.append(f"the iOS simulator lane carrieth no digest sidecar at {side.name} -- an undatable log is not "
                        f"evidence about the current tree")
    if not pre.is_file():
        problems.append(f"the iOS simulator lane carrieth no PRE-RUN digest at {pre.name} -- *a log whose source set "
                        f"was sampled only AFTER the run cannot be shown to describe one revision.*")
    if side.is_file() and pre.is_file():
        post_digest = side.read_text(encoding="utf-8").strip().split()[0]
        pre_digest = pre.read_text(encoding="utf-8").strip().split()[0]
        current = _ios_source_digest()
        if pre_digest != post_digest:
            problems.append(f"the iOS simulator lane's SOURCE SET CHANGED WHILE IT RAN: pre-run {pre_digest[:16]}… "
                            f"does not match post-run {post_digest[:16]}… -- *this log is not evidence about ANY "
                            f"single revision.*")
        elif post_digest != current:
            problems.append(f"the iOS simulator lane log is STALE: its source digest {post_digest[:16]}… does not "
                            f"match the tree's {current[:16]}… -- *the log never saw these sources. Re-run the lane.*")
    return problems, totals


def _required_simulator_arm_names() -> set[str]:
    """The source-declared SIMULATOR-COMPILABLE arm names, as `<Class>.<test>` -- used for the duplicate check above.

    *Same filter as `simulator_roster()`: a class (and its arms) wrapped in `#if os(macOS)` is one the simulator build
    compiles to nothing, so it cannot be a "required arm" here either.*
    """
    names: set[str] = set()
    for f in _simulator_compiled_sources():
        text = f.read_text(encoding="utf-8", errors="replace")
        flags = _macos_only_line_flags(text)
        m = re.search(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", text, re.M)
        cls = m.group(1) if m and _compiled_for_simulator(text, flags, m.start()) else None
        for arm in _UI_TEST_FUNC.finditer(text):
            if not _compiled_for_simulator(text, flags, arm.start()):
                continue
            names.add(f"{cls}.{arm.group(1)}" if cls else arm.group(1))
    return names


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
    for m in BUNDLE_TOTAL.finditer(text):
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
    for name, n in re.findall(r"^\s*Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?", text,
                              re.M):
        if int(name) and int(n):
            problems.append(f"the iOS lane carrieth a failing count: {name} tests, {n} failures")
    if re.search(r"^.*error: ", text, re.M):
        problems.append("the iOS lane log carrieth `error:` lines")

    # *** AND A SKIP IS REFUSED UNLESS ITS REASON NAMES AN EXTERNAL BLOCK (the same clause the simulator lane keeps). ***
    #
    # *MEASURED: this lane's own log carries ONE skipped arm whose reason reads `EXTERNAL-BLOCKED ... the pinned
    # SQLCipher library 'libsqlcipher.0.dylib' is not present on this host` -- the positive native road the plan routes
    # to EXTERNAL. **THE FOUNDATION LANE CARRIED NO SKIP CLAUSE AT ALL**, so the day a skip appeared it would either be
    # ignored (a witness reported as coverage while measuring nothing) or the whole lane refused for an arm that cannot
    # run in the builder's world. **THIS IS THE HONEST MIDDLE: that one reason is accepted, ANY OTHER reason is
    # refused.***
    skip_annotation = _skip_annotation_by_arm(text)
    for m in IOS_SKIPPED_ARM.finditer(text):
        arm = m.group(1).strip()
        reason = skip_annotation.get(arm, "")
        if not any(marker in reason for marker in IOS_EXTERNAL_SKIP_MARKERS):
            problems.append(
                f"the iOS lane carrieth a SKIPPED arm ({arm}) whose reason does NOT name an external block "
                f"(EXTERNAL-BLOCKED or the absent pinned library) -- a skipped witness reports as a pass while "
                f"measuring nothing, and only an external-blocked arm may be excused")

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
                f"{current[:16]}… -- *the lane never saw these sources, so it is not evidence about them. Re-run the "
                f"lane.*")
    # *** AND THE PRE-RUN DIGEST MUST EQUAL THE POST-RUN ONE, OR A MID-RUN EDIT STOLE THE LOG'S OWN PROVENANCE. ***
    #
    # *THE DEFECT THIS CLOSES: `run_ios_lane.sh` wrote its digest AFTER `swift test`, so an edit to a Swift source
    # BETWEEN the compile and the sidecar produced a log DESCRIBING a tree the tests never built -- **and the staleness
    # guard above CANNOT see it, because both the late digest and the tree are post-edit.*** *The runner now writes a
    # PRE-RUN digest beside it, and the two must agree.*
    pre = Path(str(IOS_LOG) + ".pre.sha256")
    if not pre.is_file():
        problems.append(
            f"the iOS lane log carrieth NO PRE-RUN digest at {pre.name} -- *a log whose source set was sampled only "
            f"AFTER the run cannot be shown to describe one revision: a mid-run edit leaves the late digest and the "
            f"current tree EQUAL, so the staleness guard is blind to it.*")
    elif sidecar.is_file():
        pre_digest = pre.read_text(encoding="utf-8").strip().split()[0]
        post_digest = sidecar.read_text(encoding="utf-8").strip().split()[0]
        if pre_digest != post_digest:
            problems.append(
                f"the iOS lane's SOURCE SET CHANGED WHILE IT RAN: pre-run {pre_digest[:16]}… does not match post-run "
                f"{post_digest[:16]}… -- *this log is not evidence about ANY single revision. Revert the concurrent "
                f"edit and re-run.*")
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
            # *** AND THE PRE-RUN DIGEST, OR EVERY CASE WOULD REDDEN FOR THE ABSENT PRE-DIGEST RATHER THAN FOR THE
            # DEFECT IT PROVOKES. *** *The runner writes both; a case that wrote only the late sidecar would be a
            # vacuous kill -- the same "the mutation must miss nothing it did not intend to hit" rule this whole
            # selftest family keeps.*
            Path(str(logp) + ".pre.sha256").write_text(real_digest, encoding="utf-8")
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
    bundle_line = re.search(
        r"(?sm)^Test Suite '[\w.]+\.xctest' passed.*?^(\s*Executed )(\d+)( tests?, with (?:0 tests? skipped and )?0 failures)",
        base)
    shrunk = base
    if bundle_line:
        shrunk = base[: bundle_line.start(2)] + str(int(bundle_line.group(2)) - 1) + base[bundle_line.end(2):]
    failed_bundle = base
    m2 = re.search(r"(?m)^\s*Executed (\d+) tests?, with (?:0 tests? skipped and )?0 failures", base)
    if m2:
        failed_bundle = base[: m2.start()] + f"\t Executed {m2.group(1)} tests, with 2 failures" + base[m2.end():]

    run_case("1. one test class' PASSED line removed", base.replace(f"Test Suite '{first}' passed", ""), "red")
    run_case("2. a class reports failed, not passed",
             base.replace(f"Test Suite '{first}' passed", f"Test Suite '{first}' failed"), "red")
    run_case("3. an outermost total short by one test (an arm swallowed)", shrunk, "red")
    run_case("4. a nonzero failure count on an outermost total", failed_bundle, "red")
    run_case("5. the run truncated to its first third",
             "\n".join(base.splitlines()[: max(1, len(base.splitlines()) // 3)]), "red")
    # *** THE SKIP GUARD (the clause this lane did not carry until now): an EXTERNAL-BLOCKED skip is accepted, ANY
    # OTHER reason is refused. *** *This lane's own log carries the pinned-SQLCipher skip; its reason is rewritten
    # WHOLE so the mutation cannot escape by leaving the marker substring behind.*
    run_case("6. a skip whose reason does NOT name an external block",
             re.sub(r"Test skipped - EXTERNAL-BLOCKED: .*$",
                    "Test skipped - FLAKY: this arm is unstable on this host and was skipped by the runner",
                    base, flags=re.M), "red")
    run_case("7. the real log, unmutated -- MUST be accepted",
             base, "green")

    width = max(len(c[0]) for c in cases)
    for name, expect, got, verdict in cases:
        print(f"   {name:<{width}}  expect={expect:<5} got={got:<5} {verdict}")
    print(f"\nfoundation selftest: {len(cases) - failures}/{len(cases)} mutations caught")
    return 1 if failures else 0


def simulator_selftest() -> int:
    """*** ADVERSARIAL MUTATIONS FOR `check_ios_simulator_lane` -- EACH MUST BE REFUSED (OR, FOR THE REAL LOG, ACCEPTED). ***

    *Three of these cases are the DEFECTS this round repaired, and each is exercised rather than described:*
      * **A (the optional skip infix):** the real log's aggregate reads `Executed 1339 tests, with 1 test skipped and 0
        failures (0 unexpected)`; the old pattern matchéth NOTHING, so the per-bundle total was EMPTY. *The skip-free
        control below proves the guard still bites a REAL count (removing one test from the skipped aggregate must
        redden the lane), so case 1 cannot pass merely because nothing is parsed.*
      * **C (the macOS-only roster):** `GsIntegration001ProcessTests` and `GsIntegration001CrossPlatformWorkerTests` are
        wrapped in `#if os(macOS)` and the simulator build compiles them to nothing. *The mutation asserts the derived
        roster NAMES NEITHER while still naming every simulator-runnable class, and that the derived arm total equals
        the 1339 the log executed.*
      * **D (the external-blocked skip):** the lane's one skip is excused ONLY when its reason names `EXTERNAL-BLOCKED`
        or the absent pinned library; changing that reason to an internal one must redden the lane.

    *The real log where one exists on this host, otherwise a shape-faithful synthetic fixture, so the guards are
    exercised either way.*
    """
    global SIMULATOR_LOG
    import tempfile

    failures = 0
    results: list[tuple[str, str, str, str]] = []   # mutation, expected, observed, verdict

    real_digest = _ios_source_digest()

    def synth() -> str:
        """A shape-faithful simulator log: the COMPILABLE roster, one skipped external arm, one bundle total."""
        classes, arms = simulator_roster()
        lines = [f"device_name=iPhone 17 Pro Max", f"device_udid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                 f"device_runtime=iOS 26.3", "toolchain=Xcode 27.0"]
        for cls in classes:
            lines.append(f"Test Suite '{cls}' started at 2026-01-01.")
            lines.append(f"Test Suite '{cls}' passed at 2026-01-01.")
        # One external-blocked skip, annotated and verdict-ed exactly as XCTest writes it.
        lines.append("/tmp/ReadinessT30Tests.swift:458: -[GodstoneMeshTests.ReadinessT30Tests "
                     "testTheDylibEngineRoundTripsWhenThePinnedLibraryIsPresent] : Test skipped - EXTERNAL-BLOCKED: "
                     "the approved pinned SQLCipher library 'libsqlcipher.0.dylib' is not present on this host")
        lines.append("Test Case '-[GodstoneMeshTests.ReadinessT30Tests "
                     "testTheDylibEngineRoundTripsWhenThePinnedLibraryIsPresent]' skipped (0.004 seconds).")
        lines.append("Test Suite 'GodstoneMeshTests.xctest' passed at 2026-01-01.")
        lines.append(f"\t Executed {arms - 1} tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 (1.0) seconds")
        lines.append("** TEST SUCCEEDED **")
        lines.append("raw_xcodebuild_rc=0")
        return "\n".join(lines) + "\n"

    if SIMULATOR_LOG.is_file():
        base = SIMULATOR_LOG.read_text(encoding="utf-8", errors="replace")
    else:
        base = synth()

    def run_case(name: str, text: str, expect: str, digest: str | None = None) -> None:
        global SIMULATOR_LOG
        nonlocal failures
        with tempfile.TemporaryDirectory() as td:
            logp = Path(td) / "ios-simulator-lane.log"
            logp.write_text(text, encoding="utf-8")
            d = real_digest if digest is None else digest
            if d is not None:
                Path(str(logp) + ".sources.sha256").write_text(d, encoding="utf-8")
                Path(str(logp) + ".pre.sha256").write_text(d, encoding="utf-8")
            saved = SIMULATOR_LOG
            SIMULATOR_LOG = logp
            try:
                probs, _tot = check_ios_simulator_lane()
            finally:
                SIMULATOR_LOG = saved
        got = "red" if probs else "green"
        verdict = "KILLED" if got == expect else "ESCAPED"
        if verdict == "ESCAPED":
            failures += 1
        results.append((name, expect, got, verdict))

    # *** A: the per-bundle total is READ, not silently dropped by the skip infix. *** *Shrinking the skipped
    # aggregate by one test must redden the lane -- which it can only do if the aggregate was parsed at all. Applied to
    # EVERY aggregate line, because XCTest re-prints the outermost total for `All tests` as well as the bundle.*
    shrunk = re.sub(r"(\n\s*Executed )(\d+)( tests?, with \d+ tests? skipped and )",
                    lambda m: m.group(1) + str(int(m.group(2)) - 1) + m.group(3), base)

    # *** D: the external-blocked reason, mutated to a fully internal one, must be REFUSED. *** *The WHOLE reason is
    # rewritten -- a mutation that merely prefixed it would still contain `pinned SQLCipher library` and would escape
    # for the wrong reason, proving nothing about the allowance.*
    internal = re.sub(r"Test skipped - EXTERNAL-BLOCKED: .*$",
                      "Test skipped - FLAKY: this arm is unstable on this host and was skipped by the runner",
                      base, flags=re.M)

    # *** AND A SKIP WHOSE VERDICT LINE CARRIES NO ANNOTATION AT ALL (an internal skip wearing no reason). ***
    no_annotation = "\n".join(l for l in base.splitlines() if "Test skipped" not in l)

    run_case("0. the real log, unmutated -- MUST be accepted", base, "green")
    run_case("1. (A) the skipped aggregate short by one test (a swallowed arm)", shrunk, "red")
    run_case("2. (D) the external-blocked reason mutated to an internal one", internal, "red")
    run_case("3. a skipped arm with NO annotation (an internal skip wearing no reason)", no_annotation, "red")
    run_case("4. no raw status line", "\n".join(l for l in base.splitlines() if not l.startswith("raw_xcodebuild_rc="))
             + "\n", "red")
    run_case("5. an empty log", "", "red")
    run_case("6. stale source digest", base, "red", digest="0" * 64)

    # *** AND THE ROSTER ITSELF: THE MACOS-ONLY CLASSES MUST BE ABSENT, THE RUNNABLE ONES PRESENT. ***
    classes, arms = simulator_roster()
    host_only = ("GsIntegration001ProcessTests", "GsIntegration001CrossPlatformWorkerTests")
    roster_faults: list[str] = []
    for name in host_only:
        if name in classes:
            roster_faults.append(f"{name} (a #if os(macOS) class is in the roster)")
    for name in ("ReadinessT30Tests", "GsIntegration001ScenarioTests", "GsIntegration001RealTransportTests"):
        if name not in classes:
            roster_faults.append(f"{name} (a simulator-runnable class is MISSING from the roster)")
    # *** AND THE HOST-ONLY FILES' OWN ARMS ARE EXCLUDED FROM THE TOTAL -- NOT MERELY THEIR CLASS NAMES. ***
    # *This is the anti-vacuity control for the filter: the naive walk (what the OLD roster did) counts every
    # `func test...`; the derived total must be the naive total MINUS exactly the arms inside `#if os(macOS)` regions
    # -- and that excluded set must be NON-EMPTY, or the derivation never bit and case 7 proved nothing.*
    naive_total = 0
    excluded_total = 0
    for rel in _simulator_target_source_dirs():
        for path in sorted((REPO / "ios" / rel).rglob("*.swift")):
            txt = path.read_text(encoding="utf-8", errors="replace")
            flags = _macos_only_line_flags(txt)
            for a in _UI_TEST_FUNC.finditer(txt):
                naive_total += 1
                if not _compiled_for_simulator(txt, flags, a.start()):
                    excluded_total += 1
    if naive_total - excluded_total != arms:
        roster_faults.append(f"the derived arm total {arms} != naive {naive_total} - excluded {excluded_total}")
    if excluded_total == 0:
        roster_faults.append("the macOS-only filter excluded ZERO arms -- the host-only files' tests are still "
                             "required by the roster")
    if roster_faults:
        failures += 1
        results.append(("7. roster names only simulator-runnable classes", "clean",
                        "; ".join(roster_faults), "ESCAPED"))
    else:
        results.append(("7. roster names only simulator-runnable classes", "clean", "clean", "KILLED"))
    # The arm total must equal what the lane's OWN PER-BUNDLE totals sum to -- the target's COMPILABLE population.
    # *The check below uses the SAME `BUNDLE_TOTAL` the checker sums, not the first `Executed` line in the log (which
    # belongs to a NESTED suite and would disagree for that reason alone).* On the real log that is 1339 (1341 declared
    # less the two host-only arms); the synthetic fixture's bundle total is built from this same roster.
    expected_total = sum(int(t) for t, _f in BUNDLE_TOTAL.findall(base)) or None
    if expected_total is not None and arms != expected_total:
        failures += 1
        results.append(("8. roster arm total equals the log's executed count", str(expected_total),
                        str(arms), "ESCAPED"))
    else:
        results.append(("8. roster arm total equals the log's executed count", str(expected_total), str(arms),
                        "KILLED"))

    width = max(len(c[0]) for c in results)
    print("\n== simulator selftest: mutation | expected | observed | verdict ==")
    for name, expect, got, verdict in results:
        print(f"   {name:<{width}}  {expect:6s} {got:6s} {verdict}")
    print(f"\nsimulator selftest: {len(results) - failures}/{len(results)} mutations caught")
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

    def run_case(name: str, text: str, sidecar: str | None, expect: str,
                 pre_sidecar: str | None = None) -> None:
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
            # *** AND THE PRE-RUN DIGEST IS WRITTEN FOR EVERY CASE. *** *The runner now takes a before-reading and the
            # checker requireth it to EQUAL the post-reading; a case that wrote only the late sidecar would redden for
            # the absent pre-digest rather than for the defect it provokes -- which is the same vacuous-kill class this
            # whole campaign existeth to remove.*
            if sidecar is not None:
                Path(str(logp) + ".pre.sha256").write_text(
                    pre_sidecar if pre_sidecar is not None else sidecar, encoding="utf-8")
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
    # *** (6) THE FORMERLY-KNOWN-RED ARM NOW FAILING MUST BE REFUSED -- THE ALLOWANCE IS RETIRED. ***
    #
    # *BEFORE THE RETIREMENT THIS CASE EXPECTED `green`: the arm was permitted to fail because a durable restore did
    # not exist and `gs-archive-005.app-witness` / `gs-final-006.ios-restoration-witness` were honestly OPEN.*
    #
    # **AND THE EXPECTATION IS NOW `red`, WHICH IS THE RETIREMENT'S WHOLE CONTENT: the defect was fixed at its root
    # (`@SceneStorage`, scene-scoped and discarded, replaced by a `UserDefaults` `ArchivePlaceStore` written at the
    # app's own transitions), so an arm that fails today is a NOVEL BREAK and must redden the lane.*** *A stale
    # allowlist can only hide something now: the failure it was written to permit no longer exists.*
    #
    # *** AND THIS CASE IS ITS OWN NEGATIVE CONTROL: if the allowance were ever quietly restored, this mutation would
    # ESCAPE -- the arm's failure would be swallowed as "the recorded known-red" -- so the retirement is enforced by
    # the court rather than by a comment.***
    run_case("6. the formerly-known-red arm failing is REFUSED (allowance retired)",
             base.replace("testGSA005DocumentReopensAfterCleanProcessDeath]' passed",
                          "testGSA005DocumentReopensAfterCleanProcessDeath]' failed"),
             real_digest, "red")
    # *** (6c) AND THE ALLOWLIST MUST ACTUALLY BE EMPTY, OR THE CASE ABOVE PROVES NOTHING. ***
    # *If `IOS_UI_KNOWN_RED` were repopulated, case 6 would still be `red` for the wrong reason -- some OTHER check --
    # and a reader would conclude the retirement held. So the map itself is asserted.*
    cases_run += 1
    if not IOS_UI_KNOWN_RED:
        results.append(("6c. the known-red allowance is EMPTY", "empty", "empty", "KILLED"))
    else:
        failures += 1
        results.append(("6c. the known-red allowance is EMPTY", "empty",
                        f"{sorted(IOS_UI_KNOWN_RED)}", "ESCAPED"))
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
    # (12b) *** A NOVEL BREAK WEARING A RECORDED ARM'S NAME MUST NOT BE EXCUSED. ***
    # *This is the hole a name-only allowlist leaves: the fixture hash-guard tripping, the app not launching, or a
    # selector break would each wear a recorded arm's name and read as the known restore gap.*
    #
    # **THE PREVIOUS BODY OF THIS CASE WAS VACUOUS** -- it removed the string `*** THE DOCUMENT MUST REOPEN AFTER A
    # CLEAN PROCESS DEATH` from the log, but that phrase liveth in the SOURCE, not the log, so the "mutation" was a
    # NO-OP returning the real GREEN log and the case ESCAPED (measured: `expect=red got=green`). **A case that
    # asserts nothing about what it mutates is not a negative control.**
    #
    # *** SINCE THE KNOWN-RED ALLOWANCE WAS RETIRED (`IOS_UI_KNOWN_RED` is now EMPTY), case 6 already covers "the
    # formerly-known-red arm fails -> red". THIS CASE NOW DEFENDS THE SURVIVING PROPERTY ITS NAME CLAIMED: an arm that
    # fails for a FOREIGN reason (its `passed` line replaced by a `failed` line whose verdict carries no recorded
    # signature) is refused BY NAME, just as a novel break anywhere else is.***
    foreign = base.replace(
        "testGSA005DocumentReopensAfterCleanProcessDeath]' passed",
        "testGSA005DocumentReopensAfterCleanProcessDeath]' failed")
    run_case("12b. a recorded arm failing for a FOREIGN reason is REFUSED", foreign, real_digest, "red")

    # (12) an empty log entirely.
    run_case("12. empty log (no arm verdicts at all)", "", real_digest, "red")

    # *** (13) A MID-RUN SOURCE EDIT: the pre-run digest differs from the post-run one. ***
    #
    # *This is the case the pre-digest exists for, and its own negative control: if the pre/post equality were ever
    # dropped, this case would ESCAPE -- the log would look current while describing a tree the tests never compiled.*
    run_case("13. a source changed while the lane ran (pre != post)", base, real_digest, "red",
             pre_sidecar="0" * 64)

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
    for m in re.finditer(r"^\s*Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?", text, re.M):
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

    # *** (d) AND THE PRE-RUN DIGEST MUST EQUAL THE POST-RUN ONE, OR A MID-RUN EDIT STOLE THE LOG'S OWN PROVENANCE. ***
    #
    # *THE DEFECT THIS CLOSES: `run_ios_ui_lane.sh` writeth the sidecar AFTER the schemes run, so an edit to a UI
    # source BETWEEN the schemes and the sidecar produceth a log that DESCRIBETH a tree the tests never compiled --
    # and the staleness guard above CANNOT see it, because both the late digest and the tree are post-edit.*
    #
    # **THE RUNNER NOW WRITETH A PRE-RUN DIGEST BESIDE IT (`<log>.pre.sha256`), AND THIS REQUIREth THE TWO TO AGREE.**
    # *An ABSENT pre-digest is refused too: a log whose runner did not take the before-reading cannot be shown to have
    # compiled one revision, and "we did not check" must not read as "it was fine".*
    pre = Path(str(IOS_UI_LOG) + ".pre.sha256")
    if not pre.is_file():
        problems.append(f"the iOS UI lane carrieth no PRE-RUN digest at {pre.name} -- *a log whose source set was "
                        f"sampled only AFTER the run cannot be shown to describe one revision: a mid-run edit leaves "
                        f"the late digest and the current tree EQUAL, so the staleness guard is blind to it.*")
    else:
        pre_digest = pre.read_text(encoding="utf-8").strip().split()[0]
        post_digest = side.read_text(encoding="utf-8").strip().split()[0] if side.is_file() else ""
        if pre_digest != post_digest:
            problems.append(
                f"the iOS UI lane's SOURCE SET CHANGED WHILE IT RAN: pre-run {pre_digest[:16]}… does not match "
                f"post-run {post_digest[:16]}… -- *the tests compiled one tree and the sidecar describeth another, so "
                f"this log is not evidence about ANY single revision. Revert the concurrent edit and re-run.*")
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
    ap.add_argument("--scope", choices=("all", "ios", "android", "ios-simulator"), default="all",
                    help="which lanes this invocation is responsible for -- *a control run inside the iOS job "
                         "cannot judge the ANDROID lanes, which a different job produces, nor the UI lane, which has "
                         "not run yet; asking it to would refuse thirteen things that are merely ABSENT*. "
                         "`ios-simulator` judges ONLY the workflow's step-13 simulator lane, whose log/bundle live "
                         "beside the repository like the other lanes'.")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--selftest-ui", action="store_true")
    ap.add_argument("--selftest-foundation", action="store_true")
    ap.add_argument("--selftest-simulator", action="store_true")
    args = ap.parse_args()
    if args.selftest_foundation:
        return foundation_selftest()
    if args.selftest_simulator:
        return simulator_selftest()
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
    # *** AND THE SIMULATOR LANE, WHICH `--scope all` AND `--scope ios` BOTH REQUIRE. ***
    #
    # *The workflow's step 13 is a lane like the other two, so `--scope ios` must judge it and `--scope all` must too;
    # `--scope ios-simulator` judgeth it ALONE, which is what the step's own control invocation uses (the other two
    # lanes' artifacts are judged by their own preceding step, and asking this one to re-judge them would refuse
    # nothing real but would duplicate the verdict).*
    if args.scope in ("all", "ios", "ios-simulator"):
        sim_probs, sim_totals = check_ios_simulator_lane()
    else:
        sim_probs, sim_totals = ([], {"suites": 0, "tests": 0, "failures": 0, "evidence": []})
    summary.append(
        f"  {'ios:simulator':<14} suites={sim_totals['suites']:<3} tests={sim_totals['tests']:<5} "
        f"failures={sim_totals['failures']} raw_rc={sim_totals.get('raw_rc')} "
        f"skipped={sim_totals.get('skipped', 0)} unfinished={sim_totals.get('unfinished_suites', 0)}"
        + ("  <- external-blocked: " + "; ".join(sim_totals["external_skips"])
           if sim_totals.get("external_skips") else "")
        + ("  <- per bundle: " + "; ".join(sim_totals.get("evidence", []))
           if sim_totals.get("evidence") else ""))
    all_problems.extend(sim_probs)
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
        # *** AND THE SIMULATOR LOG IS INCLUDED, NOT ONLY THE OTHER TWO (the same gap, one lane over). *** *A refusal
        # that names the simulator lane -- a missing `device_runtime`, an unparsed aggregate, a roster class absent --
        # forces the next reader to diagnose it, and this lane's log was NOT printed. It is now, and its tail is what
        # shows an `xcodebuild` cut off mid-suite.*
        for path in (IOS_LOG, IOS_UI_LOG, SIMULATOR_LOG):
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
    "android:labmesh": ("android/labmesh/src",),
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
    problems: list[str] = []
    if not sidecar.is_file():
        return [f"{label}: no source digest at {sidecar.name} -- *a result with no provenance cannot be dated, and an "
                f"undatable result is not evidence about the current tree. Run tools/readiness/run_android_lanes.sh.*"]
    recorded = sidecar.read_text(encoding="utf-8").strip()
    if recorded != current:
        problems.append(f"{label}: STALE -- its source digest {recorded[:16]}… does not match the tree's "
                        f"{current[:16]}… -- *the results never saw these sources. Re-run the lane.*")
    # *** AND THE PRE-RUN DIGEST MUST EQUAL THE POST-RUN ONE. ***
    # *The same contract the iOS lanes carry: a digest sampled only AFTER the run cannot show that one revision was
    # compiled, because a mid-run edit leaves the late digest and the current tree EQUAL.*
    pre = REPO / f"{safe}.pre.sha256"
    if not pre.is_file():
        problems.append(f"{label}: no PRE-RUN digest at {pre.name} -- *a result whose source set was sampled only "
                        f"AFTER the run cannot be shown to describe one revision.*")
    else:
        pre_digest = pre.read_text(encoding="utf-8").strip()
        if pre_digest != recorded:
            problems.append(f"{label}: SOURCE SET CHANGED WHILE IT RAN: pre-run {pre_digest[:16]}… does not match "
                            f"post-run {recorded[:16]}… -- *the results describe no single revision. Revert the "
                            f"concurrent edit and re-run.*")
    return problems


#: The test tree each lane compiles, for the SOURCE-side census below.
LANE_TEST_SOURCES = {
    "android:app": "android/app/src/test",
    "android:core": "android/core/src/test",
    "android:mesh": "android/mesh/src/test",
    "android:labmesh": "android/labmesh/src/test",
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
