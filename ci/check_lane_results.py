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

*** AND THE SAME CONTROL REAPETH A DOWNLOADED HOSTED RUN: *** *a fresh reader passeth `--evidence-root <dir>` (or a
caller passeth `evidence_root=`), and only the EVIDENCE READS -- the lane result XMLs, the iOS logs and their
`.sha256` sidecars -- resolve under that root. **THE SOURCE CENSUS, THE EXPECTED ARM ROSTERS AND THE SOURCE DIGESTS
STAY ROOTED AT THE REAL REPOSITORY**, because those ARE the sources each lane claims to have compiled; the checkout
is NEVER rebased. Absent the flag, every read resolves under the repository exactly as before.*

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


def _evidence_base(evidence_root: Path | None) -> Path:
    """*** THE ROOT EVERY EVIDENCE READ RESOLVES UNDER -- THE SUPPLIED ONE, OR THE CHECKOUT. ***

    *A fresh reader of a HOSTED run downloads that run's lane logs, result XMLs and digest sidecars into a scratch
    root, and the canonical verifier hands it here as `evidence_root=`. **THE CHECKOUT MUST NOT BE REBASED:** the
    SOURCE census, the expected arm rosters and the source digests all keep describing the real `REPO`, because they
    are the SOURCES the run claims to have compiled -- only the EVIDENCE reads move.* `evidence_root=None` resolves
    to `REPO`, so the local CLI and every existing caller behave exactly as before.
    """
    return Path(evidence_root) if evidence_root is not None else REPO


def _evidence_log(default: Path, evidence_root: Path | None) -> Path:
    """*** THE LANE LOG READ FROM THE EVIDENCE ROOT WHEN ONE IS SUPPLIED, ELSE THE MODULE DEFAULT. ***

    *The hosted runner's scratch root MIRRORS the checkout's layout, so the log keepeth its NAME (`ios-lane.log`,
    `ios-ui-lane.log`, `ios-simulator-lane.log`) and its digest sidecars (`<log>.sources.sha256`, `<log>.pre.sha256`)
    sit beside it under the evidence root. The module default is returned untouched when none is supplied -- which is
    also what the built-in selftests monkeypatch.*
    """
    return (Path(evidence_root) / default.name) if evidence_root is not None else default


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
    of silently widening what the control tolerates.* **AND THE PROJECT SPEC IS A SOURCE: `project.yml` SELECTS the
    targets and the arm roster is the SOURCE population a lane must reproduce, so this is read from `REPO` and is
    deliberately NOT moved by an evidence root -- only the lane LOG and its digest sidecars come from the evidence
    root.**
    """
    import yaml  # noqa: PLC0415 - imported here so a host without PyYAML degrades loudly, not at import time
    spec = yaml.safe_load(IOS_PROJECT_SPEC.read_text(encoding="utf-8"))
    out: dict[str, list[str]] = {}
    for name, target in (spec.get("targets") or {}).items():
        if target.get("type") == "bundle.ui-testing":
            out[name] = [s["path"] for s in (target.get("sources") or []) if isinstance(s, dict) and "path" in s]
    return out


def required_ui_arms() -> dict[str, list[str]]:
    """`{suite: [className.armName, ...]}` for every `bundle.ui-testing` target, derived from its own sources.

    *The arm declarations are SOURCE: the roster is read from the target's OWN configured source directories under
    `REPO`, so a downloaded lane's roster still describeth the sources it claims to have been compiled from.*
    """
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
#: **THE CLASS-LEVEL SUITE LINE -- `Test Suite '<ClassName>' passed` -- IS THE PORTABLE ONE.** *Measured: the BUNDLE
#: naming differs between toolchains (`<Target>.xctest` per target vs `<Package>PackageTests.xctest` merged), while the
#: per-class lines are IDENTICAL -- **91 of 91 in both the local and the hosted log.*** *This is what the roster is
#: compared against.*
IOS_CLASS_SUITE = re.compile(r"^Test Suite '(\w+)' passed", re.M)

#: The per-bundle totals (`Test Suite '<bundle>.xctest' passed` followed by ITS OWN outermost aggregate), used by the
#: foundation and simulator lanes. **NAMED HERE SO THE SIMULATOR LANE AND THE FOUNDATION LANE CANNOT DRIFT**: *they
#: were two copies of the same expression, and a fix to one would have left the other reading the old shape.*
#:
#: **THE `(?:and )?\d+ tests? skipped and ` INFIX IS OPTIONAL (XCODE 27.0).** *MEASURED ON THIS HOST: Xcode 27.0
#: printeth a skip-bearing aggregate as `Executed 1341 tests, with 1 test skipped and 0 failures (0 unexpected) ...`
#: while a skip-free line still reads `Executed 5 tests, with 0 failures (0 unexpected) ...`. A pattern REQUIRING the
#: failures figure immediately before `(N unexpected)` therefore matchéth the skipped form NOTHING, and the total
#: SILENTLY COLLAPSED -- the "a total nobody can reconcile with the artifact" defect class this file existeth to
#: refuse. The infix keepeth a skip-free line unchanged and leaveth the FAILURE figure at zero for `1 test skipped and
#: 0 failures`, which the skip clause below judges separately.*
BUNDLE_TOTAL = re.compile(
    r"^Test Suite '[\w.]+\.xctest' passed.*?^\s*Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?",
    re.M | re.S)
#: **THE SKIPPED-ARM VERDICT LINE -- `Test Case '-[<class> <arm>]' skipped (N seconds).`** *An arm XCTest reports as
#: skipped carrieth this line and NO `passed`/`failed` line, so it is invisible to a pass/fail census unless read by
#: name -- and the reason for the skip liveth on the ` -] : Test skipped - <REASON>` ANNOTATION XCTest printeth beside
#: the arm's source path.*
IOS_SKIPPED_ARM = re.compile(r"^Test Case '-\[([^'\]]+)\]' skipped", re.M)
#: **THE ANNOTATION THAT CARRIETH THE SKIP'S REASON** -- `<source>:<line>: -[<Module>.<Class> <arm>] : Test skipped -
#: <REASON>`. *Read only to DIAGNOSE which arm skipped and why; **it can never excuse one** (see the refusal clauses
#: below).*
IOS_SKIP_REASON = re.compile(r"-\[(?P<arm>[^\]]+)\]\s*:\s*Test skipped\s*-\s*(?P<reason>.*)$")
#: *** THE "EXTERNAL-BLOCKED" ALLOWANCE IS RETIRED -- NO SKIP IS EXCUSED. ***
#:
#: *The control USED TO accept a skip whose reason named BOTH the `EXTERNAL-BLOCKED` disposition AND the absent pinned
#: SQLCipher artifact (a marker tuple and a `_external_skip_ok` predicate once lived here).* **THAT ALLOWANCE IS GONE:
#: the pinned SQLCipher library is now REPOSITORY-BUILDABLE (`tools/supplychain/build_sqlcipher_simulator.sh`) and the
#: native owner REMOVED the last arm that XCTSkip`th for its absence -- WHICH MEANS NO SKIP IS HONEST AND NONE MAY BE
#: EXCUSED.** *A reason carrieth no weight whatever it sayeth: an `EXTERNAL-BLOCKED: … pinned SQLCipher library …`
#: reason on a DECLARED arm is refused exactly as an ordinary internal skip is (`_skip_reason_problems`).* **THE
#: SELFTEST PROVES THIS with a case that constructs exactly that historical reason and requirith it REFUSED; no marker
#: constant or excusal predicate remaineth to match it.**


def _skip_refusal(arm: str, named: str) -> str:
    """The refusal TEXT for one skipped arm -- the single place the message liveth, so a mutation of it is attributable."""
    return (
        f"carrieth a SKIPPED arm ({arm}){named} -- **NO SKIP IS EXCUSABLE**: a skipped witness reporteth as "
        f"a pass while measuring nothing, and the one external-blocked reason this control once accepted no longer "
        f"existeth (the pinned SQLCipher library is repository-buildable). Unskip the arm or remove it from the "
        f"target.")


def _skip_reason_problems(label: str, text: str) -> list[str]:
    """*** EVERY SKIP IS A FAILURE, NAMED BY ARM, REGARDLESS OF REASON. ***

    *THE REQUIREMENT (P1 realUser25): eliminate internal known-red allowances and unaccounted skips. **THERE IS NO
    EXCUSABLE SKIP:** a skip reporteth as a PASS while measuring NOTHING, and the one reason this control once
    accepted -- an absent pinned SQLCipher artifact -- no longer existeth, because the library is repository-buildable
    and the arm that used to skip for its absence was removed.* **SO THE RULE IS ABSOLUTE: any `skipped` verdict line
    fails the lane, whatever its annotation sayeth.** *The annotation is still read, ONLY to name the reason beside
    the arm in the refusal, so a reader need not open the log to see why.*
    """
    problems: list[str] = []
    skip_annotation = _skip_annotation_by_arm(text)
    for m in IOS_SKIPPED_ARM.finditer(text):
        arm = m.group(1).strip()
        reason = skip_annotation.get(arm, "")
        named = f" (reason: {reason[:120]}…)" if reason else " (no `Test skipped - <reason>` annotation)"
        problems.append(f"{label} {_skip_refusal(arm, named)}")
    return problems


def _skip_annotation_by_arm(text: str) -> dict[str, str]:
    """`{"<Module>.<Class> <arm>": reason}` from XCTest's `Test skipped - <reason>` annotations.

    *XCTest writes the arm's `skipped` VERDICT line and, beside it, an annotation of the form*
        `<source>:<line>: -[<Module>.<Class> <arm>] : Test skipped - <REASON>`
    **and the REASON is read only so the refusal can NAME it** -- *it excuseth nothing, because no skip is excusable
    (see `_skip_reason_problems`).* The annotation is one very long physical line, so the reason is read to
    end-of-line; a later annotation for the same arm overrideth an earlier one, which matches XCTest's own last-writer
    ordering.
    """
    out: dict[str, str] = {}
    for line in text.splitlines():
        ann = IOS_SKIP_REASON.search(line)
        if ann:
            out[ann.group("arm").strip()] = ann.group("reason")
    return out


def _log_observed_arms(text: str) -> set[str]:
    """Every `func test...` arm the LOG PRINTED A VERDICT FOR, as `<Class>.<arm>`.

    *A passing arm is written `Test Case '-[<Module>.<Class> <arm>]' passed`; **a SKIPPED arm carrieth a `skipped`
    VERDICT LINE and NO `passed`/`failed` line**, so the verdict pattern (`IOS_UITEST_CASE`) MISSETH it -- and a skip is
    precisely the shape a control must not read as coverage.* **THIS WALKS EVERY `Test Case '-[...]'` LINE WHATEVER ITS
    VERDICT, AND MERGES IN THE `skipped` VERDICT LINES**, so an arm that ran, failed OR was skipped is all OBSERVED
    here and a caller comparing against the source roster can tell a MISSING arm from a skipped one.

    *THE DEFECT THIS CLOSES (the "omitted arm" arm): the checkers reconciled a COUNT (`tests == SOURCES declare`), and
    a total is not a population -- **an arm missing from the log and an arm skipped out of it BOTH leave the count
    short by exactly one, so neither was caught as an omission.*** *This is the same by-stable-identity rule the UI lane
    already carrieth, applied to the two other lanes.*
    """
    observed: set[str] = set()
    for cls, arm, _verdict in IOS_UITEST_CASE.findall(text):
        observed.add(f"{cls.split('.')[-1]}.{arm}")
    for full in IOS_SKIPPED_ARM.findall(text):
        # The skipped verdict line reads `-[<Module>.<Class> <arm>]`, so the class and arm are split on the LAST space.
        body = full.strip()
        if " " in body:
            cls, arm = body.rsplit(" ", 1)
            if arm.startswith("test"):
                observed.add(f"{cls.split('.')[-1]}.{arm}")
    return observed


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


def check_ios_simulator_lane(*, evidence_root: Path | None = None) -> tuple[list[str], dict]:
    """*** THE SIMULATOR LANE: THE SOURCE ROSTER BY NAME, THE RAW STATUS, SKIPS, UNFINISHED SUITES, PRE/POST DIGESTS. ***

    *Each guard below is the replacement for one hole in the inline `>=50` grep the workflow carried.* **A green here
    meaneth: the scheme's own test action ran on a RECORDED device, every source-declared class and arm executed and
    passed, no arm was skipped, no suite was left unfinished, the raw `xcodebuild` status was zero, and the log was
    produced from ONE source revision.**

    *** `evidence_root` MOVETH THE EVIDENCE READS ONLY. *** *The log and its digest sidecars are read from the
    supplied root; `simulator_roster`, `_required_simulator_arm_names` and `_ios_source_digest` stay rooted at the
    real `REPO`, because the roster and the compared digest ARE source.*
    """
    problems: list[str] = []
    totals = {"suites": 0, "tests": 0, "failures": 0, "skipped": 0, "required_arms": 0, "evidence": []}
    log = _evidence_log(SIMULATOR_LOG, evidence_root)
    if not log.is_file():
        return ([f"the iOS simulator lane log is absent at {log} -- the workflow's step 13 has not been run "
                 f"here, and AN UNRUN LANE IS NOT A PASS"], totals)
    text = log.read_text(encoding="utf-8", errors="replace")

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
    # *** AND EVERY SOURCE-DECLARED (COMPILABLE) ARM MUST BE OBSERVED BY NAME -- A COUNT IS NOT A POPULATION. ***
    #
    # *THE DEFECT THIS CLOSES, the same one the foundation lane carried: the reconciliation below compareth the lane's
    # TOTAL against the source ARM COUNT, so **an arm that never ran paired with an extra verdict elsewhere leaveth the
    # total right** -- a count is blind to a substitution and to a swap of identities.* **THE ROSTER IS THE
    # `#if os(macOS)`-FILTERED ONE, so a host-only arm is not required here; a SKIPPED arm is OBSERVED (its name is in
    # the skipped verdict line) and is judged by the skip clause instead of being read as an omission.***
    sim_required_arms: set[str] = _required_simulator_arm_names()
    sim_observed_arms = _log_observed_arms(text)
    sim_omitted = sorted(sim_required_arms - sim_observed_arms)
    if sim_omitted:
        problems.append(f"the iOS simulator lane carrieth NO verdict for {len(sim_omitted)} source-declared arm(s): "
                        f"{sim_omitted[:6]} -- *an OMITTED arm cannot be absent from the source roster, and the total "
                        f"count cannot see it.*")
    # *** AND AN ARM THE SOURCES DO NOT DECLARE (or that the macOS-only filter EXCLUDES) IS REFUSED TOO. ***
    # *Gated on a NON-EMPTY roster so an empty derivation does not manufacture a finding against every observed arm.*
    if sim_required_arms:
        sim_unexpected = sorted(sim_observed_arms - sim_required_arms)
        if sim_unexpected:
            problems.append(f"the iOS simulator lane carrieth {len(sim_unexpected)} UNEXPECTED arm verdict(s) NOT "
                            f"declared for this target: {sim_unexpected[:6]} -- *an undeclared arm inflates the lane, "
                            f"and a host-only arm appearing here meaneth the target compiled something it should not.*")

    # (e) THE ARMS, BY NAME, WITH DUPLICATES AND SKIPS REFUSED. *A SKIP IS REFUSED UNLESS ITS REASON NAMES THE
    #     EXTERNAL BLOCK (defect D) -- the one honest skip this lane carries is an arm the plan itself routes to
    #     EXTERNAL, and blanket-refusing it would refuse a genuinely-green lane, while blanket-allowing skips would
    #     let an internal skip read as coverage. Each skipped arm's REASON is therefore read from its annotation.*
    observed: dict[str, int] = {}
    for c, n, _v in cases:
        key = f"{c.split('.')[-1]}.{n}"
        observed[key] = observed.get(key, 0) + 1
    # *** AND EVERY DUPLICATED VERDICT IS REFUSED -- NOT ONLY THE REQUIRED ARMS'. ***
    #
    # *THE DEFECT THIS CLOSES: the duplicate guard was narrowed to `key in _required_simulator_arm_names()`, so a
    # SECOND verdict for an arm the roster does not declare escaped BOTH this guard and the unexpected-arm guard (the
    # same verdict was 'expected' once) -- **a double-counted arm with no objection.*** *Measured: the real log carries
    # zero duplicates, so this broadens the refusal without reddening a green lane.*
    for key, times in sorted(observed.items()):
        if times > 1:
            problems.append(f"the iOS simulator lane carrieth {times} verdicts for arm {key} -- a duplicated arm "
                            f"would be double-counted")
    # *** EVERY SKIP IS REFUSED, BY ARM, REGARDLESS OF REASON. *** *The external-blocked allowance is retired: the
    # pinned SQLCipher library is repository-buildable and the arm that XCTSkip`th for its absence is gone, so NO skip
    # is honest and none is excused.*
    skip_problems = _skip_reason_problems("the iOS simulator lane", text)
    problems.extend(skip_problems)
    if skip_problems:
        totals["skipped"] = len(skip_problems)

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
    side = Path(str(log) + ".sources.sha256")
    pre = Path(str(log) + ".pre.sha256")
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
    """The source-declared SIMULATOR-COMPILABLE arm names, as `<Class>.<test>`. Kept as the single definition the
    simulator lane and its selftest both use, so a caller need not remember the filter's exact shape.

    *Same filter as `simulator_roster()`: a class (and its arms) wrapped in `#if os(macOS)` is one the simulator build
    compiles to nothing, so it cannot be a "required arm" here either.*
    """
    names: set[str] = set()
    for rel in _simulator_target_source_dirs():
        names |= _roster_arm_names(REPO / "ios" / rel, simulator_filtered=True)
    return names


#: *The foundation lane's roster, read from the TEST SOURCES -- the same "one source of truth, two consumers" shape as
#: the UI arm roster, and for the same reason: a hard-coded list drifteth from the tree it claims to describe.*
IOS_TEST_SOURCE_ROOT = REPO / "ios" / "Packages" / "GodstoneFoundation" / "Tests"
#: **An `XCTestCase` subclass DECLARES a suite; `swift test` printeth `Test Suite '<ClassName>' passed` for it in BOTH
#: measured toolchains** (91 of 91, locally AND hosted), *while the BUNDLE naming differs between them.*
IOS_TEST_CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", re.M)


def _roster_arm_names(root: Path, *, simulator_filtered: bool) -> set[str]:
    """`{Class.arm}` for every `func test...` declared under `root`, keyed EXACTLY as a log verdict line is.

    *`simulator_filtered` drops arms whose declaration sits inside an `#if os(macOS)` region, which is what the
    simulator target compiles to nothing -- the same derivation `simulator_roster()` carrieth.* **THE NAMES ARE KEYED
    `<Class>.<arm>` so a caller can compare them BY STABLE IDENTITY against `_log_observed_arms`, which is the only
    comparison a count cannot make.**
    """
    names: set[str] = set()
    for f in sorted(root.rglob("*.swift")):
        text = f.read_text(encoding="utf-8", errors="replace")
        flags = _macos_only_line_flags(text)
        cls_m = IOS_TEST_CLASS.search(text)
        cls = cls_m.group(1) if cls_m else None
        for arm in _UI_TEST_FUNC.finditer(text):
            if simulator_filtered and not _compiled_for_simulator(text, flags, arm.start()):
                continue
            names.add(f"{cls}.{arm.group(1)}" if cls else arm.group(1))
    return names


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


def check_ios_lane(*, evidence_root: Path | None = None) -> tuple[list[str], dict]:
    """Parse the iOS log against a SOURCE-DERIVED roster: every declared class must PASS, and the per-bundle
    totals must EQUAL the number of source-declared `func test...` arms.

    *The contract names no bundle: WHICH BUNDLES THE TOOLCHAIN EMITS IS THE TOOLCHAIN'S CHOICE, and a control that
    hard-coded the local shape refused a hosted run that executed the same 1400 tests and passed them all.*

    *** `evidence_root` MOVETH THE EVIDENCE READS ONLY. *** *The log and its `<log>.sources.sha256` /
    `<log>.pre.sha256` sidecars are read from the supplied root (the hosted runner's scratch tree), while the SOURCE
    roster (`foundation_roster`, `_roster_arm_names`) and the compared source digest (`_ios_source_digest`) stay
    rooted at the real `REPO` -- because those ARE the sources the lane claims to have compiled.*
    """
    problems: list[str] = []
    totals = {"suites": 0, "tests": 0, "failures": 0}
    log = _evidence_log(IOS_LOG, evidence_root)
    if not log.is_file():
        return ([f"the iOS lane log is absent at {log} -- the lane has not been run, and AN UNRUN LANE IS NOT A "
                 f"PASS"], totals)
    text = log.read_text(encoding="utf-8", errors="replace")
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
    # *** AND EVERY SOURCE-DECLARED ARM MUST BE OBSERVED BY NAME -- A COUNT IS NOT A POPULATION. ***
    #
    # *THE DEFECT THIS CLOSES: this checker reconciled the lane's TOTAL against the source ARM COUNT, and **a total is
    # blind to a SUBSTITUTION and to an OMISSION PAIRED WITH AN EXTRA**: `Executed 1452` against `1453 declared` catcheth
    # neither a specific arm that never ran while a different one ran twice, nor a renamed arm, because it compareth
    # NUMBERS rather than IDENTITIES.* **THE UI LANE ALREADY COMPARED BY NAME; THIS GIVES THE FOUNDATION AND SIMULATOR
    # LANES THE SAME RULE.*** *A skipped arm is OBSERVED here (its `skipped` verdict line carrieth its name), so the
    # external-blocked arm is not an omission -- it is judged by the skip clause below, which is where an unexcused
    # skip is refused.*
    required_arms = _roster_arm_names(IOS_TEST_SOURCE_ROOT, simulator_filtered=False)
    observed_arms = _log_observed_arms(text)
    omitted = sorted(required_arms - observed_arms)
    if omitted:
        problems.append(f"the iOS lane carrieth NO verdict for {len(omitted)} source-declared arm(s): {omitted[:6]} "
                        f"-- *an OMITTED arm cannot be absent from the source roster, and a count that reconciles "
                        f"cannot see it: the same by-stable-identity rule the UI lane keepeth.*")
    # *** AND AN ARM THE SOURCES DO NOT DECLARE IS REFUSED TOO -- THE "UNEXPECTED" ARM. ***
    # *A verdict for an arm the roster does not declare (a renamed selector, a foreign class) inflateth the total
    # unremarked; the pair of checks -- every declared arm OBSERVED, every observed arm DECLARED -- is what maketh the
    # comparison a population rather than a count.* **GATED ON A NON-EMPTY ROSTER, so an unreadable source tree (which
    # already reddens via the count reconciliation) does not manufacture a SECOND, misleading unexpected-arm finding.**
    if required_arms:
        unexpected_arms = sorted(observed_arms - required_arms)
        if unexpected_arms:
            problems.append(f"the iOS lane carrieth {len(unexpected_arms)} UNEXPECTED arm verdict(s) NOT declared in "
                            f"SOURCE: {unexpected_arms[:6]} -- *an undeclared arm inflates the lane.*")
    # *** AND A DUPLICATED VERDICT IS REFUSED (the UI and simulator lanes both carry this; the foundation lane did
    # NOT). *** *A second verdict for one arm double-counteth it -- it would inflate the total while every by-name
    # check still reconciled. Measured: the real log carries zero duplicates.*
    counts: dict[str, int] = {}
    for _c, _n, _v in IOS_UITEST_CASE.findall(text):
        key = f"{_c.split('.')[-1]}.{_n}"
        counts[key] = counts.get(key, 0) + 1
    for key, times in sorted(counts.items()):
        if times > 1:
            problems.append(f"the iOS lane carrieth {times} verdicts for arm {key} -- a duplicated arm would be "
                            f"double-counted")
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

    # *** EVERY SKIP IS REFUSED, BY ARM, REGARDLESS OF REASON (the external-blocked allowance is retired). ***
    #
    # *THE DEFECT THIS CLOSES: the foundation lane used to accept the ONE reason naming `EXTERNAL-BLOCKED` plus the
    # absent pinned SQLCipher artifact. **THE PINNED LIBRARY IS NOW REPOSITORY-BUILDABLE AND THE ARM THAT SKIPPED FOR
    # ITS ABSENCE WAS REMOVED, SO NO SKIP IS HONEST.*** *A reason is read ONLY to name it beside the arm; an
    # `EXTERNAL-BLOCKED … pinned SQLCipher library …` reason is now refused exactly as any internal skip.*
    problems.extend(_skip_reason_problems("the iOS lane", text))

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
    sidecar = log.with_suffix(log.suffix + ".sources.sha256")
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
    pre = Path(str(log) + ".pre.sha256")
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
    arms: list[tuple[str, str]] = []
    for m in TESTCASE.finditer(text):
        attrs, body = m.group(1), m.group(2)
        # *** `name` MUST NOT MATCH INSIDE `classname`: a `re.search(r'name="..."')` FINDETH `classname="..."`'s value
        # whenever `classname` cometh FIRST, so the TEST NAME would be read as its CLASS.*** *MEASURED: the committed
        # JUnit XML happens to write `name` before `classname`, which is the ONLY reason the count census ever held --
        # a valid JUnit file with the attributes the other way round parsed the name as the owning class.* An
        # attribute-boundary lookbehind maketh the extraction independent of order.
        nm = re.search(r'(?<![\w-])name="([^"]+)"', attrs)
        cl = re.search(r'(?<![\w-])classname="([^"]+)"', attrs)
        arms.append((cl.group(1) if cl else "", nm.group(1) if nm else "<unnamed>"))
        if body and ("failure" in body or "error" in body):
            bad.append(nm.group(1) if nm else "<unnamed>")
    return {"counts": counts, "bad": bad, "arms": arms, "bytes": len(text)}


def check_lane(label: str, pattern: str, declared: set[tuple[str, str]] | None = None, *,
               evidence_root: Path | None = None) -> list[str]:
    """Returns a list of problems for one lane. An EMPTY list means the lane carried a real result.

    *`declared` is the lane's SOURCE-DECLARED arm population (`_declared_arm_names`); when supplied, the observed arms
    are compared to it BY IDENTITY, not merely by count.*

    *** `evidence_root` MOVETH THE RESULT-FILE READS ONLY. *** *The result XMLs live under the runner's scratch tree
    (`build/test-results/...`), so a fresh reader supplyeth that root here; `declared` is SOURCE (derived from `REPO`
    by the caller) and the identity comparison therefore still compareth the downloaded results against the real
    checkout's declared arms.* `evidence_root=None` keepeth the historical behaviour: files read under `REPO`.
    """
    base = _evidence_base(evidence_root)
    problems: list[str] = []
    files = sorted(glob.glob(str(base / pattern)))
    if not files:
        # *** A LANE WITH NO RESULT FILE HAS NOT RUN. THAT IS A FAILURE, NOT AN ABSENCE OF NEWS. ***
        problems.append(f"{label}: NO RESULT FILES matched {pattern} -- the lane did not run, or was cleaned")
        return problems

    total = {"tests": 0, "skipped": 0, "failures": 0, "errors": 0}
    empty: list[str] = []
    bad_arms: list[str] = []
    seen: dict[tuple[str, str], int] = {}
    observed_ids: set[tuple[str, str]] = set()
    for f in files:
        p = Path(f)
        if p.stat().st_size == 0:
            empty.append(p.name)
            continue
        parsed = parse_suite(p)
        for k in total:
            total[k] += parsed["counts"][k]
        bad_arms.extend(f"{p.stem.replace('TEST-', '')}#{a}" for a in parsed["bad"])
        # *** A DUPLICATED `(classname, name)` IS REFUSED -- THE SAME BY-IDENTITY RULE THE iOS LANES CARRY. ***
        #
        # *THE DEFECT THIS CLOSES: the Android lanes were checked by COUNT ONLY, so a duplicated row (a re-run that
        # appended rather than replaced, or two result files carrying the same case) inflateth `tests=` while a
        # matching omission elsewhere leaveth the source census reconciled -- **the exact substitution a count cannot
        # see.*** **THE KEY IS `(classname, name)`, NOT THE NAME ALONE: two DIFFERENT classes legitimately carrieth the
        # same method name (MEASURED: `android:mesh` carrieth 5 such names across `ReadinessT24Test` and
        # `ReadinessT24PublicationTest`), so keying on the name alone would refuse a green lane.**
        for key in parsed["arms"]:
            seen[key] = seen.get(key, 0) + 1
            # THE CLASS TOKEN IS NORMALIZED TO ITS LAST SEGMENT, so an FQCN `io.godstone.mesh.RouterTest` compareth
            # against the source roster's simple name -- the same normalization the iOS lanes use.
            observed_ids.add((key[0].split(".")[-1], key[1]))

    if empty:
        problems.append(f"{label}: {len(empty)} EMPTY result file(s): {empty[:3]}")
    dups = sorted(k for k, v in seen.items() if v > 1)
    if dups:
        named = [f"{c}#{n}" if c else n for c, n in dups[:5]]
        problems.append(f"{label}: {len(dups)} DUPLICATED case(s) -- the same `(classname, name)` carrieth more than "
                        f"one result: {named} -- *a duplicated arm inflates `tests=` while a matching omission leaves "
                        f"the source census reconciled.*")
    # *** AND THE DECLARED-vs-OBSERVED IDENTITY COMPARISON (ManifestReview, critical). ***
    problems.extend(_roster_identity_problems(label, declared, observed_ids))
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

    passed = 0
    total = 0
    def record_check(ok: bool, desc: str, detail: str = "") -> None:
        nonlocal passed, total
        total += 1
        if ok:
            passed += 1
            print(f"   PASS: {desc}")
        else:
            print(f"   FAIL: {desc}{' -- ' + detail if detail else ''}")

    print("== selftest: an empty/absent lane result must be caught ==")
    with tempfile.TemporaryDirectory() as td:
        # 1. NO FILES AT ALL.
        global REPO
        saved = REPO
        REPO = Path(td)
        probs = check_lane("no-files", "*.xml")
        record_check(bool(probs), f"a lane with no results is REFUSED ({probs[0][:70]}...)" if probs else "a lane with no results is REFUSED",
                     "a lane with no results was ACCEPTED")

        # 2. A ZERO-TEST SUITE -- THE EXACT SHAPE A BROKEN BUILD PRODUCES.
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="0" skipped="0" failures="0" errors="0"></testsuite>',
            encoding="utf-8")
        probs = check_lane("zero-tests", "*.xml")
        record_check(bool(probs and "ZERO TESTS" in probs[0]), 'tests="0" is REFUSED rather than read as a pass',
                     "a zero-test suite was ACCEPTED")

        # 3. A SKIPPED ARM.
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="1" skipped="1" failures="0" errors="0">'
            '<testcase name="a"/></testsuite>', encoding="utf-8")
        probs = check_lane("skipped", "*.xml")
        record_check(bool(probs and "SKIPPED" in probs[0]), "a skipped arm is REFUSED",
                     "a skipped arm was ACCEPTED")

        # 4. *** THE SELF-CLOSING TRAP: A PASSING CASE FOLLOWED BY A FAILING ONE. The naive pattern attributes the
        #    failure to the PASSING name -- so this mutation proves the parser does not.
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="2" skipped="0" failures="1" errors="0">'
            '<testcase name="passes"/>'
            '<testcase name="theRealFailure"><failure message="boom"/></testcase>'
            '</testsuite>', encoding="utf-8")
        parsed = parse_suite(Path(td) / "TEST-x.xml")
        record_check(parsed["bad"] == ["theRealFailure"],
                     "the failure is attributed to the FAILING arm, not the passing one",
                     f"attribution was shifted -- got {parsed['bad']}")

        # 4b. *** A DUPLICATED `(classname, name)` IS REFUSED. *** *A re-run that appended rather than replaced, or
        #     two result files carrying the same case, inflateth `tests=` -- and a matching omission elsewhere leaveth
        #     the source census reconciled, which is the substitution a count cannot see.*
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="2" skipped="0" failures="0" errors="0">'
            '<testcase classname="C" name="a"/>'
            '<testcase classname="C" name="a"/>'
            '</testsuite>', encoding="utf-8")
        probs = check_lane("dup-arm", "*.xml")
        record_check(bool(probs and any("DUPLICATED" in p for p in probs)),
                     "a duplicated (classname, name) is REFUSED", f"a duplicated arm was ACCEPTED: {probs}")
        # *AND THE KEY IS (classname, name), NOT THE NAME ALONE: two DIFFERENT classes legitimately carrieth the same
        # method name (MEASURED in android:mesh), so this shape MUST stay green or the guard would refuse a real lane.*
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="2" skipped="0" failures="0" errors="0">'
            '<testcase classname="C1" name="a"/>'
            '<testcase classname="C2" name="a"/>'
            '</testsuite>', encoding="utf-8")
        probs = check_lane("same-name-two-classes", "*.xml")
        record_check(not any("DUPLICATED" in p for p in probs),
                     "the same method name in TWO classes is NOT a duplicate",
                     f"a legitimate same-name-two-classes lane was refused: {probs}")

        # 4c. *** A UNIQUE UNDECLARED ARM SWAPPED FOR A DECLARED ONE -- THE MANIFESTREVIEW CRITICAL, WHERE THE COUNT
        #     STILL RECONCILES. *** *The declared population is one arm `C#b`; the observed XML carrieth a DIFFERENT
        #     arm `C#z` (same size), so the identity comparison is what refuseth it -- a count never could.*
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="1" skipped="0" failures="0" errors="0">'
            '<testcase classname="C" name="z"/></testsuite>', encoding="utf-8")
        probs = check_lane("substituted-arm", "*.xml", declared={("C", "b")})
        record_check(bool(probs and any("OBSERVED arm" in p or "NEVER OBSERVED" in p for p in probs)),
                     "a same-size class/method SUBSTITUTION is REFUSED by identity",
                     f"a substituted arm was ACCEPTED: {probs}")
        # *And the DECLARED set matching EXACTLY must stay GREEN -- else the guard would refuse a real lane.*
        probs = check_lane("matching-arm", "*.xml", declared={("C", "z")})
        record_check(not any("NEVER OBSERVED" in p or "OBSERVED arm" in p for p in probs),
                     "a declared set that matches the observed arms is NOT refused",
                     f"an exactly-matching roster was refused: {probs}")
        # *AND A NORMALIZED FQCN OBSERVED NAME MATCHES THE SIMPLE-NAME ROSTER (the XML carrieth `a.b.C`, the sources
        # say `C`), or every real lane would be refused for the wrong reason.*
        (Path(td) / "TEST-x.xml").write_text(
            '<?xml version="1.0"?><testsuite name="x" tests="1" skipped="0" failures="0" errors="0">'
            '<testcase classname="io.godstone.C" name="z"/></testsuite>', encoding="utf-8")
        probs = check_lane("fqcn-arm", "*.xml", declared={("C", "z")})
        record_check(not any("NEVER OBSERVED" in p or "OBSERVED arm" in p for p in probs),
                     "an FQCN observed name matches the simple-name roster",
                     f"an FQCN name was not normalized: {probs}")
        # *And a SIZE MISMATCH is left to the count census, not to the identity diff (no false red on attribution
        # noise) -- so a declared set of a different size must NOT raise an identity finding.*
        probs = check_lane("size-mismatch", "*.xml", declared={("C", "z"), ("C", "extra")})
        record_check(not any("NEVER OBSERVED" in p or "OBSERVED arm" in p for p in probs),
                     "an unequal-size population is left to the count census",
                     f"the identity check fired on a size mismatch: {probs}")

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
        record_check(bool(unjudged and all("NOT JUDGED HERE" in r for r in unjudged)),
                     "a lane outside the scope is marked NOT JUDGED", f"got {unjudged}")
        record_check(not any(re.search(r"tests=\d", r) for r in unjudged),
                     "an unjudged lane carrieth NO COUNT AT ALL", f"got {unjudged}")
        # *The mutation is the OLD rendering. It must be distinguishable from the repaired one, or this case would
        # pass against the defect too.*
        old_rendering = f"  {'ios:foundation':<14} suites={0:<3} tests={0:<5} failures={0}"
        record_check(not any(r == old_rendering for r in unjudged),
                     "the old zero-count rendering is gone", "defective rendering is still emitted")
        # *And the in-scope branch must still carry REAL counts -- a rule that silenced every lane would be a
        # different defect wearing this repair's clothes.*
        judged = ios_scope_rows("ios", real, {"suites": 2, "tests": 12, "failures": 1}, ["LabMeshUITests"])
        record_check(bool(any("tests=1400" in r for r in judged) and any("tests=12" in r for r in judged)),
                     "an in-scope lane still carrieth its real counts", f"got {judged}")

        # 5b. Scope matrix validation across all five supported scopes:
        sim_real = {"suites": 83, "tests": 1338, "failures": 0, "raw_rc": 0, "evidence": ["1338 tests / 0 failures"]}
        host_judged = ios_scope_rows("ios-host", real, {"suites": 2, "tests": 12, "failures": 0}, ["LabMeshUITests"])
        record_check(bool(any("tests=1400" in r for r in host_judged) and any("tests=12" in r for r in host_judged)),
                     "ios-host carries real foundation and ui counts", f"got {host_judged}")

        sim_host = simulator_scope_row("ios-host", sim_real)
        record_check(bool("NOT JUDGED HERE" in sim_host and "tests=" not in sim_host),
                     "ios-host marks simulator as NOT JUDGED without zero counts", f"invalid: {sim_host}")

        sim_android = simulator_scope_row("android", sim_real)
        record_check(bool("NOT JUDGED HERE" in sim_android and "tests=" not in sim_android),
                     "android marks simulator as NOT JUDGED without zero counts", f"invalid: {sim_android}")

        sim_ios = simulator_scope_row("ios", sim_real)
        record_check(bool("tests=1338" in sim_ios and "NOT JUDGED" not in sim_ios),
                     "ios scope carries real simulator counts (aggregate all-3)", f"invalid: {sim_ios}")

        sim_sim = simulator_scope_row("ios-simulator", sim_real)
        record_check(bool("tests=1338" in sim_sim and "NOT JUDGED" not in sim_sim),
                     "ios-simulator scope carries real simulator counts", f"invalid: {sim_sim}")

        sim_all = simulator_scope_row("all", sim_real)
        record_check(bool("tests=1338" in sim_all and "NOT JUDGED" not in sim_all),
                     "all scope carries real simulator counts", f"invalid: {sim_all}")

        REPO = saved

    print(f"\nselftest: {passed}/{total} checks passed")
    return 0 if (passed == total and total > 0) else 1


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
    real_fresh = IOS_LOG.is_file() and Path(str(IOS_LOG) + ".sources.sha256").is_file() and \
        Path(str(IOS_LOG) + ".sources.sha256").read_text(encoding="utf-8").strip() == real_digest
    if real_fresh:
        base = IOS_LOG.read_text(encoding="utf-8", errors="replace")
    else:
        # *** THE SYNTHETIC LOG IS BUILT FROM THE SOURCE ROSTER'S OWN ARMS, BY NAME -- AND FROM NOTHING ELSE. ***
        #
        # *THE DEFECT THIS CLOSES IN THE FIXTURE (first form): it emitted one `testSomething` per class, so once the
        # checker required every SOURCE-DECLARED arm BY NAME (`_log_observed_arms`) the synthetic base reddened for
        # arms it never carried -- a selftest fixture that provokes the very guard it is meant to be NEUTRAL toward.*
        #
        # *** AND THE DEFECT THIS CLOSES IN THE FIXTURE (second form): it ALSO fabricated `skipped` verdicts and
        # skip ANNOTATIONS for a hard-coded EXTERNAL-BLOCKED arm (`ReadinessT30Tests`' pinned-SQLCipher round-trip)
        # that the sources have SINCE REMOVED -- the pinned library is now repository-buildable, so no arm
        # XCTSkip`th for its absence.*** *A fixture that invents an arm the sources do not declare violates the
        # checker's own by-identity rule (`observed - required` = UNEXPECTED), so the unmutated case reddened FOR THE
        # FIXTURE'S OWN STALE LITERAL rather than for any guard.* **THE POSITIVE CASE NOW CARRIES EXACTLY THE
        # SOURCE-DECLARED ARMS, EACH PASSING -- the honest minimal shape a green log of THESE sources must have -- and
        # the checker is NOT relaxed and NO skip is re-pinned.** *The skip clauses (cases 6, 7a, and the simulator
        # suite's own skip control) construct their own synthetic skip lines inline, so their coverage is unchanged.*
        arms_by_class: dict[str, list[str]] = {}
        required_arm_names = _roster_arm_names(IOS_TEST_SOURCE_ROOT, simulator_filtered=False)
        for key in required_arm_names:
            cls, arm = key.rsplit(".", 1)
            arms_by_class.setdefault(cls, []).append(arm)
        _arms = len(required_arm_names)
        lines = []
        for cls in sorted(arms_by_class):
            lines.append(f"Test Suite '{cls}' started at 2026-01-01.")
            for arm in sorted(arms_by_class[cls]):
                lines.append(f"Test Case '-[{cls} {arm}]' passed (0.001 seconds).")
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
    # *** THE DECLARED ARMS, SORTED, FOR THE CONTROLS THAT NEED ONE BY NAME. *** *`skip_arm` drives the skip clause's
    # synthetic fixture and `omitted_arm` the by-identity omission; they are the two ENDS of the same list so they
    # cannot collide.*
    _declared_arms_sorted = sorted(_roster_arm_names(IOS_TEST_SOURCE_ROOT, simulator_filtered=False))
    skip_arm = _declared_arms_sorted[0] if _declared_arms_sorted else "SyntheticTests.testSomething"
    # The mutation must bite on THIS host's log shape. The local shape sums per-target bundles; the hosted shape is
    # one merged bundle. *Whichever the log carries, reduce ONE outermost total by one test.*
    # *** THE MUTATION MUST BITE AN **OUTERMOST BUNDLE TOTAL**, NOT A NESTED SUITE'S. ***
    #
    # **MEASURED: decrementing the FIRST `Executed` line ESCAPED, because the first one belongs to a nested suite whose
    # total is not part of the sum** -- *so the mutation changed nothing the control reads, and an ESCAPED verdict there
    # would have said "the guard is broken" when the truth was "the mutation missed".* **The line that matters is the
    # one that FOLLOWS a `Test Suite '<bundle>.xctest' passed`**, which is exactly what the parser sums.
    bundle_line = re.search(
        r"(?sm)^Test Suite '[\w.]+\.xctest' passed.*?^(\s*Executed )(\d+)( tests?, with (?:\d+ tests? skipped and )?0 failures)",
        base)
    shrunk = base
    if bundle_line:
        shrunk = base[: bundle_line.start(2)] + str(int(bundle_line.group(2)) - 1) + base[bundle_line.end(2):]
    failed_bundle = base
    m2 = re.search(r"(?m)^\s*Executed (\d+) tests?, with (?:\d+ tests? skipped and )?0 failures", base)
    if m2:
        failed_bundle = base[: m2.start()] + f"\t Executed {m2.group(1)} tests, with 2 failures" + base[m2.end():]

    run_case("1. one test class' PASSED line removed", base.replace(f"Test Suite '{first}' passed", ""), "red")
    run_case("2. a class reports failed, not passed",
             base.replace(f"Test Suite '{first}' passed", f"Test Suite '{first}' failed"), "red")
    run_case("3. an outermost total short by one test (an arm swallowed)", shrunk, "red")
    run_case("4. a nonzero failure count on an outermost total", failed_bundle, "red")
    run_case("5. the run truncated to its first third",
             "\n".join(base.splitlines()[: max(1, len(base.splitlines()) // 3)]), "red")
    # *** THE SKIP GUARD, NOW ABSOLUTE: EVERY SKIP IS REFUSED, WHATEVER ITS REASON. *** *(P1 realUser25: eliminate
    # internal known-red allowances and unaccounted skips. The external-blocked allowance that once accepted the pinned
    # SQLCipher reason is RETIRED -- the library is repository-buildable and the arm that skipped for its absence is
    # gone, so no skip is honest.)*
    #
    # *THE FIXTURE IS CONSTRUCTED HERE, NOT READ FROM `base`: the skip clause must be exercised BY AN ARM THE SOURCES
    # DECLARE (`skip_arm`), with a `skipped` verdict line AND its `Test skipped - <reason>` annotation, so it passeth
    # the by-identity roster check and the ONLY guard it provoketh is the skip clause itself.* **THE PREVIOUS FORM WAS
    # A HARD-CODED `ReadinessT30Tests`/pinned-SQLCipher skip that the sources have SINCE REMOVED** -- *it read `base`
    # and rewrote a skip line such a log may not carry, so `re.sub` no-opped and the case mutated NOTHING.*
    def _without_skip_arm_verdicts(text: str) -> str:
        """Remove EVERY verdict line for `skip_arm` (its `passed` line included) so the ONLY verdict this control adds
        is the single `skipped` one -- **otherwise the case would redden for a DUPLICATE verdict rather than for the
        skip clause, a vacuous kill.**"""
        name = skip_arm.split(".")[-1]
        return "\n".join(
            l for l in text.splitlines()
            if "Test skipped" not in l
            and not (l.startswith("Test Case '-[") and f" {name}]'" in l))

    def _with_skip(reason: str) -> str:
        cls, name = skip_arm.split(".", 1)
        return _without_skip_arm_verdicts(base) + (
            f"\n/tmp/{cls}.swift:1: -[{cls} {name}] : Test skipped - {reason}\n"
            f"Test Case '-[{cls} {name}]' skipped (0.004 seconds).\n")
    # An ORDINARY INTERNAL skip -- refused.
    run_case("6. an ordinary internal skip (any reason)",
             _with_skip("FLAKY: this arm is unstable on this host and was skipped by the runner"), "red")
    # *** 7a. THE HISTORICAL EXTERNAL-BLOCKED REASON -- THE ONE THE RETIRED ALLOWANCE WOULD HAVE EXCUSED -- IS NOW
    # REFUSED TOO. *** *This is the P1 realUser25 core: a reason naming `EXTERNAL-BLOCKED` AND the pinned SQLCipher
    # library must NOT buy an exemption. **IF THE ALLOWANCE WERE EVER REPOPULATED, THIS CASE WOULD ESCAPE** -- which
    # makes it the control that pins the retirement.*
    run_case("7a. the historical EXTERNAL-BLOCKED + pinned-artifact reason -- STILL REFUSED",
             _with_skip("EXTERNAL-BLOCKED: the approved pinned SQLCipher library 'libsqlcipher.0.dylib' is not "
                        "present on this host"), "red")
    # *** 7a'. A SKIP WEARING THE ARTIFACT'S VOCABULARY WITHOUT THE DISPOSITION -- ALSO REFUSED. ***
    #
    # *THE DEFECT THIS PROVES CLOSED: the old rule was a bare substring search, so a reason reading `the pinned
    # SQLCipher library built fine but this arm is flaky` was ACCEPTED -- **an internal skip dressed in the external
    # exemption's own words.*** *Now EVERY skip is refused, so this shape is refused for the same reason as any other.*
    run_case("7a'. a skip naming the artifact without the disposition -- REFUSED",
             _with_skip("the pinned SQLCipher library built fine but this arm is flaky on this host"), "red")
    # *** 7b. AND AN ARM OMITTED FROM THE LOG ENTIRELY -- A COUNT IS NOT A POPULATION. ***
    #
    # *This is the "omitted arm" case: ONE source-declared arm's verdict line is removed while every OTHER line and
    # every bundle total stay untouched, so the COUNT still reconciles and ONLY the by-identity roster sees it.* *If
    # the by-name check were ever dropped, this case would ESCAPE -- which is what makes it a control rather than a
    # comment.* **THE REMOVED ARM IS CHOSEN FROM THE DECLARED ROSTER AND FROM THE FAR END OF THE SAME SORTED LIST THE
    # SKIP CONTROL DRAWS ITS ARM FROM, so the two controls cannot operate on the same arm** (removing an arm the skip
    # control also skipped would make one case's verdict depend on the other's).
    omitted_arm = _declared_arms_sorted[-1] if _declared_arms_sorted else "SyntheticTests.testSomething"
    run_case("7b. one source-declared arm omitted from the log (count reconciles)",
             "\n".join(l for l in base.splitlines()
                       if not (l.startswith("Test Case '-[") and omitted_arm.split(".")[-1] in l)),
             "red")
    # *** 7c. AN ARM THE SOURCES DO NOT DECLARE IS REFUSED. ***
    run_case("7c. a verdict for an arm the sources do NOT declare (unexpected arm)",
             base + "\nTest Case '-[GodstoneMeshTests.GodstoneMeshTests testThisArmWasNeverDeclared]' passed "
                    "(0.001 seconds).\n", "red")
    # *** 7d. A DUPLICATED VERDICT IS REFUSED (the foundation lane carried no duplicate guard at all). ***
    dup_arm = omitted_arm  # any arm the base carries a passed line for
    run_case("7d. a duplicated verdict for one arm",
             base + f"\nTest Case '-[{dup_arm.split('.')[0]} {dup_arm.split('.')[-1]}]' passed (0.001 seconds).\n",
             "red")
    run_case("8. the real log, unmutated -- MUST be accepted",
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
        the sources' compilable population.*
      * **D (EVERY skip is refused):** the external-blocked allowance is RETIRED -- the pinned SQLCipher library is
        repository-buildable and the arm that XCTSkip`th for its absence is gone. *BOTH an ordinary internal skip AND
        the historical `EXTERNAL-BLOCKED … pinned SQLCipher library …` reason must redden the lane.*

    *The real log where one exists on this host, otherwise a shape-faithful synthetic fixture, so the guards are
    exercised either way.*
    """
    global SIMULATOR_LOG
    import tempfile

    failures = 0
    results: list[tuple[str, str, str, str]] = []   # mutation, expected, observed, verdict

    real_digest = _ios_source_digest()

    def synth() -> str:
        """A shape-faithful simulator log: EVERY COMPILABLE source-declared arm BY NAME, ALL PASSED, one total."""
        lines = ["device_name=iPhone 17 Pro Max", "device_udid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                 "device_runtime=iOS 26.3", "toolchain=Xcode 27.0"]
        # *** EVERY COMPILABLE ARM THE SOURCES DECLARE, keyed EXACTLY as `_required_simulator_arm_names()` derives them,
        # and EVERY ONE OF THEM PASSING -- ZERO SKIPS.*** *THE FIXTURE IS THEREFORE ENTIRELY SOURCE-DERIVED AND ENTIRELY
        # GREEN: it provoketh NO by-identity (`unexpected`), count, OR skip guard -- the honest shape a green log of
        # THESE sources must have once every arm passes (the last XCTSkip-for-absence arm is gone; the pinned library is
        # repository-buildable).* **THE DEFECT THIS REPLACES: the fixture hard-coded a `ReadinessT30Tests`/pinned-SQLCipher
        # skip arm the sources have SINCE REMOVED, so the fabricated arm failed the `observed - required` rule and
        # reddened the unmutated case for the FIXTURE'S OWN stale literal.** *The skip clause is exercised instead by
        # the adversarial cases, which construct a skip on a DECLARED arm.*
        required_arms: list[str] = sorted(_required_simulator_arm_names())
        for cls in sorted({k.rsplit(".", 1)[0] for k in required_arms}):
            lines.append(f"Test Suite '{cls}' started at 2026-01-01.")
            lines.append(f"Test Suite '{cls}' passed at 2026-01-01.")
        for key in required_arms:
            cls, arm = key.rsplit(".", 1)
            lines.append(f"Test Case '-[{cls} {arm}]' passed (0.001 seconds).")
        lines.append("Test Suite 'GodstoneMeshTests.xctest' passed at 2026-01-01.")
        _classes, arms = simulator_roster()
        lines.append(f"\t Executed {arms} tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds")
        lines.append("** TEST SUCCEEDED **")
        lines.append("raw_xcodebuild_rc=0")
        return "\n".join(lines) + "\n"

    # *** THE REAL LOG IS USED ONLY WHEN IT STILL AGREE WITH THE SOURCES. ***
    #
    # *THE DEFECT THIS CLOSES IN THE SELFTEST, AND IT BIT: a sibling edited the iOS sources WHILE this file was being
    # hardened, so the committed `ios-simulator-lane.log` declared 1339 arms while the tree NOW declares more -- and the
    # real log then REDDENED case 0 ("unmutated MUST be accepted") and disagreed with case 12's derived total.* **A
    # STALE LOG IS THE CHECKER'S OWN VERDICT, NOT A FAULT IN THE GUARD**; exercising the guard on a stale base would
    # report a guard failure that is really a stale artifact.* **SO THE BASE IS THE REAL LOG ONLY WHILE ITS SIDECAR
    # MATCHES THE CURRENT DIGEST, else the shape-faithful SYNTHETIC fixture (whose arm names and total are read from
    # the SAME source-derived roster the checker uses, so it can never drift).**
    real_fresh = False
    if SIMULATOR_LOG.is_file():
        side = Path(str(SIMULATOR_LOG) + ".sources.sha256")
        real_fresh = side.is_file() and side.read_text(encoding="utf-8").strip().split()[0] == real_digest
    if real_fresh:
        base = SIMULATOR_LOG.read_text(encoding="utf-8", errors="replace")
    else:
        base = synth()

    # *** THE SKIP CONTROLS ARE BUILT ON AN ARM THE SOURCES DECLARE -- NEVER ON A HARD-CODED ARM OR A `re.sub` THAT
    # MAY NO-OP. *** *`sim_skip_key` is a declared (simulator-compilable) arm; `_strip_skips` removeth every existing
    # skip verdict and its annotation, and `_with_skip` addeth back ONE skip for that arm carrying the reason the case
    # requires. **SO THE ONLY SKIP THE CHECKER SEES IS THE ONE THIS CONTROL CONSTRUCTED**, and the arm it belongeth to
    # is always in the source roster -- no by-identity or omission guard is provoked by accident, and the case reddens
    # FOR THE SKIP CLAUSE AND NOTHING ELSE.* **MEASURED DEFECT THIS REPLACES: a hard-coded `ReadinessT30Tests` skip
    # arm the sources have since removed, and `re.sub` rewrites that no-opped on a base lacking the line -- a vacuous
    # kill on one host and an outright ESCAPE on another.***
    sim_req_sorted = sorted(_required_simulator_arm_names())
    sim_skip_key = sim_req_sorted[0] if sim_req_sorted else "SyntheticTests.testSomething"
    sim_skip_cls, sim_skip_name = sim_skip_key.rsplit(".", 1)

    def _strip_skips(text: str) -> str:
        return "\n".join(l for l in text.splitlines()
                         if "Test skipped" not in l
                         and not (l.startswith("Test Case '-[") and "]' skipped" in l))

    def _without_skip_arm_verdicts(text: str) -> str:
        """Remove EVERY verdict line for `sim_skip_key` (its `passed` line included) so the ONLY verdict added back is
        the single `skipped` one -- **otherwise the case would redden for a DUPLICATE verdict rather than for the skip
        clause, a vacuous kill.**"""
        return "\n".join(
            l for l in _strip_skips(text).splitlines()
            if not (l.startswith("Test Case '-[") and f" {sim_skip_name}]'" in l))

    def _with_skip(reason: str) -> str:
        return _without_skip_arm_verdicts(base) + (
            f"\n/tmp/{sim_skip_cls}.swift:1: -[{sim_skip_cls} {sim_skip_name}] : Test skipped - {reason}\n"
            f"Test Case '-[{sim_skip_cls} {sim_skip_name}]' skipped (0.004 seconds).\n")

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

    # *** A: the per-bundle total is READ, not silently dropped by the OPTIONAL `N tests skipped and` infix (Xcode
    # 27.0's skip-bearing aggregate shape). *** *A skip-BEARING aggregate must still have its count parsed, so
    # shrinking that count by one must redden the lane via the arm-total reconciliation -- which can only happen if the
    # aggregate was parsed at all.* **THE SKIP-BEARING AGGREGATE IS CONSTRUCTED ON THE OUTERMOST (BUNDLE) TOTAL OF A
    # DETERMINISTIC ALL-PASSED FIXTURE, because the POSITIVE fixture carrieth NO skip** -- *this is an aggregate COUNT
    # line, not a skipped ARM verdict, so it introduceth no excused skip. AND IT MUST BE THE OUTERMOST LINE: the
    # checker sums only the `…xctest passed` bundle's own total, so mutating a NESTED suite's line would change nothing
    # the parser reads (a measured ESCAPE in an earlier round).*
    _fixture_green = synth()
    agg = re.search(
        r"(?sm)^Test Suite '[\w.]+\.xctest' passed.*?^(\s*Executed )(\d+)( tests?, with )0 failures",
        _fixture_green)
    skip_infix_base = _fixture_green
    shrunk = _fixture_green
    if agg:
        skipped_shape = (_fixture_green[: agg.start(3)] + "1 test skipped and 0 failures"
                         + _fixture_green[agg.end(3) + len("0 failures"):])
        skip_infix_base = skipped_shape
        shrunk = (skipped_shape[: skipped_shape.index(agg.group(2), agg.start(2))]
                  + str(int(agg.group(2)) - 1)
                  + skipped_shape[skipped_shape.index(agg.group(2), agg.start(2)) + len(agg.group(2)):])

    # *** D: EVERY SKIP IS REFUSED, WHATEVER ITS REASON -- the external-blocked allowance is RETIRED. *** *The pinned
    # SQLCipher library is repository-buildable and the arm that XCTSkip`th for its absence is gone, so no skip is
    # honest.* **THE SKIP IS REBUILT ON A DECLARED ARM (`_with_skip`), so the case cannot be vacuous (a `re.sub` on a
    # base that lacks the line would mutate nothing).**
    internal = _with_skip("FLAKY: this arm is unstable on this host and was skipped by the runner")
    # *** AND THE HISTORICAL EXTERNAL-BLOCKED + pinned-artifact REASON -- the one the retired allowance would have
    # excused -- IS NOW REFUSED TOO. *** *IF THE ALLOWANCE WERE EVER REPOPULATED, THIS CASE WOULD ESCAPE, so it is the
    # control that pins the retirement.*
    external_blocked = _with_skip("EXTERNAL-BLOCKED: the approved pinned SQLCipher library 'libsqlcipher.0.dylib' "
                                  "is not present on this host")

    # *** AND A SKIP WHOSE VERDICT LINE CARRIES NO ANNOTATION AT ALL (an internal skip wearing no reason). ***
    no_annotation = _strip_skips(base) + (
        f"\nTest Case '-[{sim_skip_cls} {sim_skip_name}]' skipped (0.004 seconds).\n")

    run_case("0. the real log, unmutated -- MUST be accepted", base, "green")
    run_case("1. (A) the skipped aggregate short by one test (a swallowed arm)", shrunk, "red")
    run_case("2. (D) an ordinary internal skip (any reason)", internal, "red")
    run_case("2b. (D) the historical EXTERNAL-BLOCKED + pinned-artifact reason -- STILL REFUSED",
             external_blocked, "red")
    run_case("3. a skipped arm with NO annotation (an internal skip wearing no reason)", no_annotation, "red")
    run_case("4. no raw status line", "\n".join(l for l in base.splitlines() if not l.startswith("raw_xcodebuild_rc="))
             + "\n", "red")
    run_case("5. an empty log", "", "red")
    run_case("6. stale source digest", base, "red", digest="0" * 64)
    # *** 7. A SKIP WEARING THE EXEMPTION'S VOCABULARY BUT NOT ITS DISPOSITION -- ALSO REFUSED. ***
    # *Naming the artifact buyeth nothing; every skip is refused.*
    run_case("7. a skip naming the artifact but NOT the EXTERNAL-BLOCKED disposition",
             _with_skip("the pinned SQLCipher library built fine but this arm is flaky on this host"), "red")
    # *** 8. ONE COMPILABLE ARM OMITTED FROM THE LOG -- A COUNT IS NOT A POPULATION. ***
    #
    # *ONE source-declared (simulator-compilable) arm's verdict line is removed while every total stays put, so the
    # arm-total reconciliation still passeth and ONLY the by-name roster sees the omission.* **THE OMITTED ARM IS CHOSEN
    # FROM THE DECLARED ROSTER AND FROM THE FAR END OF THE SAME SORTED LIST THE SKIP CONTROL DRAWS ITS ARM FROM, so it
    # cannot be the skipped arm** (whose verdict line is the skip clause's, not this omission's).
    sim_omit = sim_req_sorted[-1] if sim_req_sorted and sim_req_sorted[-1] != sim_skip_key else sim_skip_key
    run_case("8. one source-declared arm omitted from the log (count reconciles)",
             "\n".join(l for l in base.splitlines()
                       if not (l.startswith("Test Case '-[") and sim_omit.split(".")[-1] in l)), "red")
    # *** 9. AN ARM THE SOURCES DO NOT DECLARE FOR THIS TARGET IS REFUSED. ***
    run_case("9. a verdict for an arm the sources do NOT declare (unexpected arm)",
             base + "\nTest Case '-[GodstoneMeshTests.GodstoneMeshTests testThisArmWasNeverDeclared]' passed "
                    "(0.001 seconds).\n", "red")
    # *** 10. A DUPLICATED VERDICT IS REFUSED -- AND FOR AN ARM THE ROSTER DOES NOT DECLARE, which the OLD
    # narrowed guard (`key in required`) let escape both this check and the unexpected check. ***
    dup_sim = sim_omit
    run_case("10. a duplicated verdict (the old guard's narrow window)",
             base + f"\nTest Case '-[{dup_sim.split('.')[0]} {dup_sim.split('.')[-1]}]' passed (0.001 seconds).\n",
             "red")

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
        results.append(("11. roster names only simulator-runnable classes", "clean",
                        "; ".join(roster_faults), "ESCAPED"))
    else:
        results.append(("11. roster names only simulator-runnable classes", "clean", "clean", "KILLED"))
    # The arm total must equal what the lane's OWN PER-BUNDLE totals sum to -- the target's COMPILABLE population.
    # *The check below uses the SAME `BUNDLE_TOTAL` the checker sums, not the first `Executed` line in the log (which
    # belongs to a NESTED suite and would disagree for that reason alone).* On the real log that is 1339 (1341 declared
    # less the two host-only arms); the synthetic fixture's bundle total is built from this same roster.
    expected_total = sum(int(t) for t, _f in BUNDLE_TOTAL.findall(base)) or None
    if expected_total is not None and arms != expected_total:
        failures += 1
        results.append(("12. roster arm total equals the log's executed count", str(expected_total),
                        str(arms), "ESCAPED"))
    else:
        results.append(("12. roster arm total equals the log's executed count", str(expected_total), str(arms),
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
        # *** THE REAL LOG IS USED ONLY WHEN IT STILL AGREETH WITH THE SOURCES *** (the same freshness rule the
        # foundation and simulator families keep): a stale committed log is the CHECKER'S verdict, not a fault in the
        # guard, so exercising the guard on it would report a false failure.
        ui_side = Path(str(IOS_UI_LOG) + ".sources.sha256")
        if IOS_UI_LOG.is_file() and ui_side.is_file() and \
                ui_side.read_text(encoding="utf-8").strip().split()[0] == real_digest:
            return IOS_UI_LOG.read_text(encoding="utf-8", errors="replace")
        # A synthetic but shape-faithful log, used when no lane has been run on this host (or its log is stale).
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
    # *** (11b) AN ARM THE SOURCES DO NOT DECLARE IS REFUSED -- THE "UNEXPECTED ARM", which the old lane let pass. ***
    #
    # *THE DEFECT THIS CLOSES: this lane checked MISSING and DUPLICATE arms by name but not UNEXPECTED ones, so a
    # verdict for a renamed selector or a foreign class bundled into a UI target inflated `tests=` unremarked.* *The
    # invented arm is a class the roster declares but an arm NAME it does not, so it lands in neither the required set
    # nor the duplicate set -- **only the unexpected check can see it**, which is what makes this case the negative
    # control for that guard.*
    run_case("11b. a verdict for an arm the sources do NOT declare (unexpected arm)",
             base + "\nTest Case '-[LabMeshUITests.LabMeshUITests testGSINT001AnArmThatWasNeverDeclared]' passed (1.0 seconds).\n",
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


def check_ios_ui_lane(*, evidence_root: Path | None = None) -> tuple[list[str], dict]:
    """*** THE `bundle.ui-testing` LANE: EVERY ARM'S OWN LINE, ZERO-EXECUTED REFUSED, STALENESS BOUND. ***

    *Modelled on `check_ios_lane`, with the three guards that make a UI log honest:*
      * a REQUIRED SUITE LIST, so a target that stops running is not silently absent;
      * **`Executed 0` IS A FAILURE** -- `swift test` prints it from an inner probe, and an XCUITest run reports it
        when the runner crashes before completing, which is exactly how `Executed 4, 0 failures` appeared beside
        `** TEST FAILED **` this session;
      * **ANY SKIP IS A FAILURE**, because a skipped UI arm reports as a pass while measuring nothing;
      * and the log is bound to the SAME SOURCE DIGEST the package lane uses, so a UI edit invalidates it.

    *** `evidence_root` MOVETH THE EVIDENCE READS ONLY. *** *The log and its digest sidecars are read from the
    supplied root; `required_ui_arms`, the source digest and `IOS_PROJECT_SPEC` stay rooted at the real `REPO`.*
    """
    problems: list[str] = []
    totals = {"suites": 0, "tests": 0, "failures": 0, "evidence": []}
    log = _evidence_log(IOS_UI_LOG, evidence_root)
    if not log.is_file():
        return ([f"the iOS UI lane log is absent at {log} -- the UI targets have not been run, and AN UNRUN "
                 f"LANE IS NOT A PASS"], totals)
    text = log.read_text(encoding="utf-8", errors="replace")

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
    required_keys: set[str] = set()
    for suite in IOS_UI_REQUIRED_SUITES:
        for arm in roster.get(suite, []):
            totals["required_arms"] += 1
            key = arm                      # already "<Class>.<test>"
            required_keys.add(key)
            if (arm.split(".")[0], arm.split(".")[1]) not in observed:
                problems.append(f"*** REQUIRED UI ARM ABSENT: {key} is DECLARED IN SOURCE but the log carrieth NO "
                                f"verdict for it. *** *An arm that never ran is not a passing arm -- this is the "
                                f"defect a count cannot see.*")
    # *** AND AN ARM THE SOURCES DO NOT DECLARE IS REFUSED TOO (the "unexpected" arm). ***
    #
    # *THE DEFECT THIS CLOSES: this lane checked MISSING arms by name and DUPLICATES, but not UNEXPECTED ones -- so a
    # verdict for an arm the roster does not declare (a renamed selector, a foreign class bundled into a UI target)
    # would inflate `tests=` and pass UNREMARKED.* **THE SIMULATOR AND FOUNDATION LANES GET THE SAME PAIR OF
    # CHECKS: every source-declared arm must be OBSERVED, and every observed arm must be DECLARED.**
    #
    # *AND THE CHECK IS GATED ON A NON-EMPTY ROSTER: when the roster could not be derived the UNOBTAINABLE-ROSTER
    # problem above already reddens the lane, so an empty `required_keys` must not ALSO manufacture an "unexpected"
    # finding -- which would be a SECOND, misleading red for one cause.*
    if required_keys:
        observed_keys = {f"{c.split('.')[-1]}.{n}" for c, n, _v in cases}
        unexpected = sorted(observed_keys - required_keys)
        if unexpected:
            problems.append(f"the iOS UI lane carrieth {len(unexpected)} UNEXPECTED arm verdict(s) NOT declared in "
                            f"SOURCE: {unexpected[:6]} -- *an arm the roster does not declare cannot be omitted from a "
                            f"green count, and a verdict for it inflates the lane.*")
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
    side = Path(str(log) + ".sources.sha256")
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
    pre = Path(str(log) + ".pre.sha256")
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
    if scope in ("all", "ios", "ios-host"):
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


def simulator_scope_row(scope: str, sim_totals: dict) -> str:
    """The simulator row of the summary, for a given scope. Exercised directly by `--selftest`."""
    if scope in ("all", "ios", "ios-simulator"):
        return (
            f"  {'ios:simulator':<14} suites={sim_totals['suites']:<3} tests={sim_totals['tests']:<5} "
            f"failures={sim_totals['failures']} raw_rc={sim_totals.get('raw_rc')} "
            f"skipped={sim_totals.get('skipped', 0)} unfinished={sim_totals.get('unfinished_suites', 0)}"
            # *** NO EXCUSAL IS PRINTED: a skipped arm is a REFUSAL, not a noted allowance (P1 realUser25). ***
            + ("  <- per bundle: " + "; ".join(sim_totals.get("evidence", []))
               if sim_totals.get("evidence") else "")
        )
    return f"  {'ios:simulator':<14} NOT JUDGED HERE -- the simulator lane stands outside `--scope {scope}`"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", choices=("all", "ios", "ios-host", "android", "ios-simulator"), default="all",
                    help="which lanes this invocation is responsible for -- *a control run inside the iOS job "
                         "cannot judge the ANDROID lanes, which a different job produces. "
                         "`ios-host` judges ONLY the host-macOS foundation and UI lanes (run early before the "
                         "simulator build); `ios` judges ALL THREE iOS lanes; `ios-simulator` judges the simulator "
                         "lane alone; and `all` judges every lane in the repository.*")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--selftest-ui", action="store_true")
    ap.add_argument("--selftest-foundation", action="store_true")
    ap.add_argument("--selftest-simulator", action="store_true")
    # *** THE EVIDENCE ROOT: WHERE THE LANE ARTIFACTS LIVE WHEN THEY ARE NOT UNDER THE CHECKOUT. ***
    #
    # *A fresh reader of a HOSTED run downloads that run's lane logs, result XMLs and digest sidecars into a scratch
    # root and passeth it here -- the canonical verifier's `lane results` gate already invokes this CLI with
    # `--evidence-root {evidence_root}`. **THE CHECKOUT IS NEVER REBASED:** the SOURCE census, the expected arm
    # rosters and the source digests keep describing the real repository, because those ARE the sources the lanes
    # claim to have compiled; only the EVIDENCE reads (the XML files, the iOS logs and their `.sha256` sidecars) move.
    # Absent, every read resolves under the checkout exactly as before.*
    ap.add_argument("--evidence-root", default=None,
                    help="read the lane RESULT FILES and LOGS under this root (source census and digests stay at the "
                         "repository root); defaults to the repository root")
    args = ap.parse_args()
    if args.selftest_foundation:
        return foundation_selftest()
    if args.selftest_simulator:
        return simulator_selftest()
    if args.selftest_ui:
        return ui_selftest()
    if args.selftest:
        return selftest()

    evidence_root = Path(args.evidence_root) if args.evidence_root else None
    evidence_base = _evidence_base(evidence_root)
    all_problems: list[str] = []
    summary: list[str] = []
    for label, task_dir, pattern in (LANES if args.scope in ("all", "android") else ()):
        probs = check_lane(label, pattern, declared=_declared_arm_names(label), evidence_root=evidence_root)
        files = glob.glob(str(evidence_base / pattern))
        # *** AND AN UNEXPECTED SIBLING UNDER `test-results/` IS REFUSED BY NAME (round 745). ***
        #
        # *A sibling means SOMEONE RAN A FILTERED SUITE beside the lane* -- the courts and the mutation harness both do --
        # **and while the glob above no longer sums it, its PRESENCE is the warning that the lane's own directory may be a
        # partial generation.** *This is the same "two trees, one claim" shape that let a stray report directory inflate
        # the mesh lane to 1906 for eight verifications.*
        results_root = (evidence_base / pattern).parent.parent
        if results_root.is_dir():
            siblings = sorted(d.name for d in results_root.iterdir()
                              if d.is_dir() and d.name != task_dir)
            if siblings:
                try:
                    shown_root = results_root.relative_to(evidence_base)
                except ValueError:
                    shown_root = results_root
                all_problems.append(
                    f"{label}: `{shown_root}` carrieth UNEXPECTED SIBLING DIRECTORIES {siblings} "
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
        all_problems.extend(_android_source_digest_problems(label, evidence_root=evidence_root))
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

    # *** AND THE REPORT-BEARING ANDROID LANES (ui / simulator / production), WHICH THIS CONTROL DID NOT JUDGE. ***
    #
    # *THE GAP THIS CLOSES, MEASURED: the four historical unit lanes are judged above by their digest sidecars and
    # their `build/test-results/` XML. **THE THREE LANES THAT RAN A FILTER (the rendered-controls UI lane, the lab
    # simulator lane, the production-simulation lane) COULD NOT BE: a filtered run writeth BESIDE another task's
    # directory -- the pollution the sibling rule above refuseth -- so those lanes carry their OWN evidence root, their
    # OWN report, and this control re-derives their verdict from `tools/readiness/lane_registry.py`.***
    #
    # *** AND IT IS A FAIL-CLOSED READ: an ABSENT report is a REFUSAL (an unrun lane is not a pass), the digest is
    # recomputed from the REAL tree, the counts are re-parsed from the REAL XML, and the raw gradle status must be
    # zero. NOTHING is taken from the report's own `verdict` field -- the checker re-deriveth it.***
    if args.scope in ("all", "android"):
        for lane in _report_lane_ids():
            all_problems.extend(_report_lane_problems(lane, evidence_root=evidence_root))
            all_problems.extend(_report_lane_isolation_problems(lane, evidence_root=evidence_root))
            summary.append(_report_lane_row(lane, evidence_root=evidence_root))

    ios_probs, ios_totals = check_ios_lane(evidence_root=evidence_root) if args.scope in ("all", "ios", "ios-host") else ([], {"suites": 0, "tests": 0, "failures": 0, "evidence": []})
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
    if args.scope in ("all", "ios", "ios-host"):
        ui_probs, ui_totals = check_ios_ui_lane(evidence_root=evidence_root)
    else:
        # *Same rule as `ios:foundation` above, and for the same measured reason: never a zero for a lane this scope
        # did not judge.*
        ui_probs, ui_totals = ([], {"suites": 0, "tests": 0, "failures": 0, "known_red": 0})

    # *** THE iOS ROWS COME FROM ONE DEFINITION (`ios_scope_rows`), WHICH `--selftest` EXERCISETH DIRECTLY. ***
    # *A lane outside the scope sayeth so and carrieth NO COUNT; a lane inside it carrieth its real counts. **Both
    # branches are the same call, so the selftest cannot drift from the shipped rendering.***
    summary.extend(ios_scope_rows(args.scope, ios_totals, ui_totals, list(IOS_UI_REQUIRED_SUITES)))
    # *** AND THE SIMULATOR LANE, WHICH `--scope all`, `--scope ios` AND `--scope ios-simulator` JUDGE. ***
    #
    # *`--scope ios` is the aggregate all-3 iOS control (invoked after simulator execution, requiring all three
    # lanes: foundation, UI, simulator). `--scope ios-host` judgeth only the host-macOS foundation and UI lanes
    # (invoked early before the simulator build, with simulator marked NOT JUDGED HERE). `--scope ios-simulator`
    # judgeth the simulator lane alone. `--scope all` judgeth all lanes together.*
    if args.scope in ("all", "ios", "ios-simulator"):
        sim_probs, sim_totals = check_ios_simulator_lane(evidence_root=evidence_root)
        all_problems.extend(sim_probs)
    else:
        sim_probs, sim_totals = ([], {"suites": 0, "tests": 0, "failures": 0, "evidence": []})
    summary.append(simulator_scope_row(args.scope, sim_totals))
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
        for path in (_evidence_log(IOS_LOG, evidence_root), _evidence_log(IOS_UI_LOG, evidence_root),
                     _evidence_log(SIMULATOR_LOG, evidence_root)):
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


def _android_source_digest_problems(label: str, *, evidence_root: Path | None = None) -> list[str]:
    """The lane's result files must have been produced from THESE sources, not from a revision nobody can date.

    *** THE SIDECARS ARE EVIDENCE AND COME FROM THE EVIDENCE ROOT; THE COMPARED DIGEST IS SOURCE AND COMES FROM
    `REPO`.*** *The hosted runner writeth `<lane>.sources.sha256` and `<lane>.pre.sha256` at its scratch root, so a
    reader supplyeth that root here; the digest those files are compared AGAINST is recomputed from the real
    checkout's Kotlin bytes (`_android_source_digest`), because those ARE the sources the lane claims to have
    compiled.* `evidence_root=None` keepeth the historical behaviour: sidecars read from `REPO`.
    """
    base = _evidence_base(evidence_root)
    safe = label.replace(":", "-")
    sidecar = base / f"{safe}.sources.sha256"
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
    pre = base / f"{safe}.pre.sha256"
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

#: `.kt` is the file whose FIRST `class`/`object` declaration owns the `@Test`s below it.
_LANE_CLASS_DECL = re.compile(r"\b(class|object)\s+([A-Za-z_]\w*)")
#: A `@Test`-bearing method: a bare `@Test`, an indented `@Test fun`, or a bare `@Test` line above a `fun`.
#: *** KOTLIN ALLOWETH A BACKTICK-QUOTED METHOD NAME (`fun `a sentence with spaces`()`), AND THE JUNIT XML CARRIETH
#: THAT NAME VERBATIM *** *-- measured in `android:mesh`, where many `@Test` methods are so named; a matcher that
#: accepted only `[A-Za-z_]\w*` saw NONE of them and the declared roster fell short by exactly those.*
_LANE_TEST_FUN = re.compile(r"\bfun\s+(?:`([^`\n]+)`|([A-Za-z_]\w*))\s*\(")
_LANE_TEST_SLICE = 400


def _kotlin_class_spans(text: str) -> list[tuple[int, int, str]]:
    """`[(start, end, className)]` for every `class`/`object` BODY in `text`, by BRACE depth.

    *** KOTLIN SCOPING IS BY BRACES, NOT BY DECLARATION ORDER. *** *MEASURED: `GsFinal006RenderedReadingListTest.kt`
    declares a helper `TwoDocReader` BETWEEN two of the outer class's methods, so a naive "nearest declaration above"
    attribution assigns the outer class's LATER methods to the helper -- a false roster that would redden a green lane.*
    **THIS SCAN therefore strips comments and string/char literals (which may carrieth braces), then followeth the
    brace stack so a method is owned by the class BODY it actually sits in.**
    """
    # A minimal Kotlin lexer for the only thing we need here: the brace structure OUTSIDE comments and literals.
    stack: list[tuple[int, str | None]] = []   # (brace_depth_at_open, class name or None)
    spans: list[tuple[int, int, str]] = []
    depth = 0
    pending_class: str | None = None
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c in "\"'":
            quote = c
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                if text[i] == "\n" and quote == "'":
                    break
                i += 1
            continue
        if c == "{" :
            stack.append((depth, pending_class))
            if pending_class is not None:
                spans.append((i, -1, pending_class))
            pending_class = None
            depth += 1
            i += 1
            continue
        if c == "}":
            if stack:
                open_depth, name = stack.pop()
                if name is not None:
                    for k in range(len(spans) - 1, -1, -1):
                        if spans[k][2] == name and spans[k][1] == -1:
                            spans[k] = (spans[k][0], i, name)
                            break
            depth = max(0, depth - 1)
            i += 1
            continue
        if c.isalpha() or c == "_":
            m = _LANE_CLASS_DECL.match(text, i)
            if m:
                pending_class = m.group(2)
                i = m.end()
                continue
            # skip an identifier
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            i = j
            continue
        i += 1
    return spans


def _declared_arm_names(label: str) -> set[tuple[str, str]] | None:
    """`{(FQCN, method)}` for every `@Test` the lane's own sources declare -- the POPULATION a run must reproduce.

    *** THE DEFECT THIS CLOSES (ManifestReview, critical): the Android lanes were compared by COUNT and DUPLICATE keys
    only, so `Executed 1324` against a source census of 1324 accepted **a UNIQUE UNDECLARED arm swapped for a declared
    one -- a class/method substitution that keepeth the total identical.*** *A count is not a population: the iOS lanes
    were already strengthened to compare declared-vs-observed BY STABLE IDENTITY, and this giveth the Android lanes the
    same rule.*

    *THE OWNER IS THE innermost class BODY (`_kotlin_class_spans`) whose declaration nameth the FILE's stem -- Kotlin's
    own convention, which the JUnit XML `classname` also followeth (MEASURED: 1:1 across all four lanes). A file with
    NO stem-named class returns `None`, so the caller NAMETH it rather than computing a false roster.*
    """
    base = REPO / LANE_TEST_SOURCES.get(label, "")
    if not base.is_dir():
        return None
    arms: set[tuple[str, str]] = set()
    unresolved: list[str] = []
    for f in base.rglob("*.kt"):
        text = f.read_text(encoding="utf-8", errors="replace")
        spans = _kotlin_class_spans(text)
        stem_spans = [(a, b) for a, b, name in spans if name == f.stem and b >= 0]
        if text.count("@Test") and not stem_spans:
            unresolved.append(f.name)
            continue
        for m in re.finditer(r"@Test", text):
            # The innermost stem-named class body that CONTAINS this @Test.
            if not any(a <= m.start() <= b for a, b in stem_spans):
                continue
            fn = _LANE_TEST_FUN.search(text, m.end(), m.end() + _LANE_TEST_SLICE)
            if fn:
                arms.add((f.stem, fn.group(1) if fn.group(1) is not None else fn.group(2)))
    if unresolved:
        # An `@Test`-bearing file whose test class we could not locate means we cannot compute a trustworthy roster.
        return None
    return arms


def _roster_identity_problems(label: str, declared: set[tuple[str, str]] | None,
                              observed: set[tuple[str, str]]) -> list[str]:
    """Declared-vs-observed arm IDENTITY problems for one Android lane -- a PURE function so a court can refute it.

    *** THE DEFECT THIS CLOSES (ManifestReview, critical): the Android lanes were compared by COUNT and duplicate keys
    only, so a UNIQUE UNDECLARED class/method swapped for a declared one -- with the total unchanged -- passed.***

    **THE CHECK IS GATED ON EQUAL POPULATION SIZE, WHICH IS EXACTLY THE SUBSTITUTION CASE AND NOTHING ELSE.** *When the
    declared and observed POPULATIONS carrieth the same number of arms, a substitution is the ONLY thing that can
    differ, so comparing identities is both MEANINGFUL and SAFE. When the sizes differ, the count census
    (`_source_test_census`) already nameth the under/over-count, and an identity diff would be dominated by attribution
    noise (a helper class, a generated name) rather than signal -- so this returneth `[]` and leaves that case to the
    count, rather than reddening a green lane for a reason the operator cannot act on.*
    """
    if declared is None or len(declared) != len(observed):
        return []
    problems: list[str] = []
    missing = sorted(declared - observed)
    unexpected = sorted(observed - declared)
    if missing:
        named = [f"{c}#{n}" for c, n in missing[:5]]
        problems.append(f"{label}: {len(missing)} source-declared arm(s) NEVER OBSERVED (the count still reconciled): "
                        f"{named} -- *an OMITTED arm cannot be absent from the source roster.*")
    if unexpected:
        named = [f"{c}#{n}" for c, n in unexpected[:5]]
        problems.append(f"{label}: {len(unexpected)} OBSERVED arm(s) the sources do NOT declare: {named} -- *a "
                        f"substitution that keepeth the total is exactly what a count cannot see.*")
    return problems


# ================================================================================================
# *** THE REPORT-BEARING ANDROID LANES: ui / simulator / production. ***
#
# *These three run a FILTERED gradle invocation (`--tests ...`), and a filtered run writeth its reports into a SIBLING
# task directory beside the lane's own -- the exact pollution the unit lanes' sibling rule refuseth. So each carries
# its OWN evidence root (`android-ui-results/`, `android-simulator-results/`, `android-production-results/`) and its
# OWN report, and the verdict is re-derived from the REAL sources, the REAL XML and the child's OWN status by
# `tools/readiness/lane_registry.py`.*
#
# **THE ONE IMPORT RULE: the registry is imported LAZILY.** *`check_lane_results` is loaded by many callers (the
# manifest adapter, the courts, `check_release_gates_status`); a module-level import of a sibling tree would couple
# them all to a path that need not exist for the unit-lane judgements. A missing registry is a NAMED refusal, never an
# ImportError at load time.*
# ================================================================================================

def _lane_registry():
    """Load `tools/readiness/lane_registry.py` as a module (no package), or raise ImportError with a real message."""
    import importlib.util
    registry_path = REPO / "tools" / "readiness" / "lane_registry.py"
    if not registry_path.is_file():
        raise ImportError(f"the lane registry is absent at {registry_path} -- *the report-bearing lanes cannot be "
                          f"judged without the ONE definition of their targets and evidence.*")
    spec = importlib.util.spec_from_file_location("lane_registry_under_test", registry_path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def _report_lane_ids() -> tuple[str, ...]:
    """The lanes whose verdict comes from a report, from the registry (empty if it cannot be read)."""
    try:
        return tuple(_lane_registry().REPORT_LANES)
    except ImportError:
        return ()


def _report_lane_problems(lane: str, *, evidence_root: Path | None = None) -> list[str]:
    """Re-derive one report lane's verdict. A registry that cannot be read is a NAMED refusal, never a silent pass."""
    try:
        registry = _lane_registry()
    except ImportError as exc:
        return [f"{lane}: {exc}"]
    return list(registry.verify_lane_report(lane, evidence_root=evidence_root))


def _report_lane_isolation_problems(lane: str, *, evidence_root: Path | None = None) -> list[str]:
    """*** THE REPORT LANE'S EVIDENCE DIRECTORY MUST CARRY ONLY ITS OWN COPIED FILES. ***

    *The lane's report nameth every file it copied, with each file's sha256. A file present but UNNAMED is either a
    stranger (another lane's run leaked in, and a shared denominator is exactly what the sibling rule refuseth by name)
    or a tampered addition. An UNNAMED file is therefore refused, and a NAMED file whose bytes moved is refused too --
    a report whose digests no longer describe the directory is a report about nothing.*
    """
    try:
        registry = _lane_registry()
    except ImportError as exc:
        return [f"{lane}: {exc}"]
    registry_spec = registry.LANE_SPECS.get(lane)
    if not registry_spec or not registry_spec.get("report"):
        return []
    base = _evidence_base(evidence_root)
    doc, problems = registry._load_report(base, registry_spec)
    if doc is None:
        return []          # the absent-report refusal already fired in _report_lane_problems
    results_dir = base / Path(registry_spec["results_glob"]).parent
    named = dict((doc.get("results") or {}).get("sha256") or {})
    present = sorted(p.name for p in results_dir.glob("*.xml")) if results_dir.is_dir() else []
    strangers = [name for name in present if name not in named]
    if strangers:
        problems.append(f"{lane}: its evidence directory carrieth file(s) the report does NOT name: {strangers} -- "
                        f"*a filtered run writeth beside its own task directory, so an unnamed file is another run's "
                        f"output leaking into this lane's denominator.*")
    for name, recorded in sorted(named.items()):
        path = results_dir / name
        if not path.is_file():
            problems.append(f"{lane}: the report nameth {name} but it is ABSENT from the evidence directory")
            continue
        live = registry._sha256_file(path)
        if live != recorded:
            problems.append(f"{lane}: {name} has changed since the report bound it ({str(recorded)[:16]}… vs "
                            f"{live[:16]}…) -- *a result file edited after binding is not the run's own output.*")
    return problems


def _report_lane_row(lane: str, *, evidence_root: Path | None = None) -> str:
    """The summary row for a report lane -- its REAL counts, or an explicit NOT JUDGED/ABSENT marker."""
    try:
        registry = _lane_registry()
    except ImportError:
        return f"  {lane:<18} REGISTRY ABSENT -- not judged"
    spec = registry.LANE_SPECS.get(lane)
    base = _evidence_base(evidence_root)
    doc, _ = registry._load_report(base, spec)
    if doc is None:
        return f"  {lane:<18} ABSENT -- no report at {spec['report']} (the lane did not run)"
    junit = doc.get("junit") or {}
    return (f"  {lane:<18} files={junit.get('files', 0):<3} tests={junit.get('tests', 0):<5} "
            f"skipped={junit.get('skipped', 0)} failures={junit.get('failures', 0)} errors={junit.get('errors', 0)} "
            f"raw_rc={doc.get('raw_rc')}  <- {doc.get('verdict')}")


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
