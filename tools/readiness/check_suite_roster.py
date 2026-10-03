#! /usr/bin/env python3
"""Execute the readiness suite with source-derived identities and recorded unittest outcomes.

Every internal case must pass; skips, expected failures and unexpected successes do not
discharge required behavior. Historical capture-dependent cases are classified from
their actual defining file and recognized decorator. Counts and full identities must
match discovery exactly.

The bounded child records lifecycle events, not verdict-shaped stdout. Raw output and
a digest-bound result sidecar remain outside the repository, including failed runs.

Usage:
    python3 tools/readiness/check_suite_roster.py --run --log /tmp/readiness.log --roster /tmp/roster.json
    python3 tools/readiness/check_suite_roster.py --log /tmp/readiness.log
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import ast
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
TESTS = ROOT / "tools" / "readiness" / "tests"

#: *** THE DECORATORS THAT DEFER AN ARM, AND THE KIND OF ABSENCE EACH NEEDS. ***
#:
#: *A decorator not in this map is NOT a deferral mechanism this control recognises -- so an arm deferred by some new
#: mechanism appears as an unaccounted skip and is REFUSED rather than silently accepted.*
DEFERRAL_DECORATORS = {
    "historical_arm": "HISTORICAL",
    "requires_capture": "HISTORICAL",
}

#: The reason a category is excluded, stated once so the roster carries prose as well as identity.
CATEGORY_REASON = {
    "HISTORICAL": ("needs an out-of-repository capture (the T01 preservation inventory or the builder evidence "
                   "root). The bytes are absent from a clean clone by design, so the arm DEFERS there rather than "
                   "claiming a pass."),
}


def _decorator_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    if isinstance(node, ast.Call):
        return _decorator_name(node.func)
    return None


def _decorator_index(scan_root: Path) -> dict[tuple[Path, str, str], str]:
    """Index declarations by their defining file, class and method, not a module-name suffix."""
    index: dict[tuple[Path, str, str], str] = {}
    for path in sorted(scan_root.rglob("test_*.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except (OSError, SyntaxError):
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.ClassDef):
                continue
            for item in node.body:
                if not isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                if not item.name.startswith("test"):
                    continue
                for dec in item.decorator_list:
                    name = _decorator_name(dec)
                    if name in DEFERRAL_DECORATORS:
                        index[(path.resolve(), node.name, item.name)] = name
                        break
    return index


def derive_roster(discovered_ids: list[str], scan_root: Path) -> dict:
    """Classify the discovered population using its actual defining modules and source decorators."""
    index = _decorator_index(scan_root)
    excluded: list[dict] = []
    internal: list[str] = []
    for test_id in discovered_ids:
        module_name, class_name, method_name = test_id.rsplit(".", 2)
        module = sys.modules.get(module_name)
        source = getattr(module, "__file__", None)
        dec = index.get((Path(source).resolve(), class_name, method_name)) if source else None
        if dec:
            excluded.append({
                "id": test_id,
                "decorator": f"@{dec}",
                "category": DEFERRAL_DECORATORS[dec],
                "reason": CATEGORY_REASON[DEFERRAL_DECORATORS[dec]],
            })
        else:
            internal.append(test_id)
    return {
        "source": "discovery population classified by an AST decorator scan (recursive under tools/readiness)",
        "deferral_decorators": DEFERRAL_DECORATORS,
        "excluded": sorted(excluded, key=lambda e: e["id"]),
        "internal": sorted(internal),
        "counts": {
            "collected": len(discovered_ids),
            "excluded_historical": len(excluded),
            "internal_required": len(internal),
        },
    }


def collect_test_ids(suite: unittest.TestSuite | None = None) -> dict:
    """Enumerate the same discovered suite that will execute, without running any test."""
    if suite is None:
        prev = os.getcwd()
        try:
            os.chdir(ROOT)
            suite = unittest.TestLoader().discover(str(TESTS))
        finally:
            os.chdir(prev)
    ids: list[str] = []
    stack = [suite]
    while stack:
        node = stack.pop()
        if isinstance(node, unittest.TestSuite):
            stack.extend(list(node))
        else:
            ids.append(node.id())
    return {"ids": sorted(ids), "total": len(ids)}


class RecordedResult(unittest.TextTestResult):
    """Record unittest lifecycle outcomes independently of test output and docstrings."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.executions: list[dict] = []
        self._active: dict[str, dict] = {}

    def startTest(self, test):
        row = {"id": test.id(), "outcome": "incomplete", "failures": 0, "errors": 0}
        self.executions.append(row)
        self._active[test.id()] = row
        super().startTest(test)

    def _record(self, test, outcome):
        row = self._active.get(test.id())
        if row is None:
            row = {"id": test.id(), "outcome": "incomplete", "failures": 0, "errors": 0}
            self.executions.append(row)
            self._active[test.id()] = row
        if outcome == "failure":
            row["failures"] += 1
        elif outcome == "error":
            row["errors"] += 1
        row["outcome"] = outcome

    def addSuccess(self, test):
        self._record(test, "ok")
        super().addSuccess(test)

    def addSkip(self, test, reason):
        self._record(test, "skipped")
        super().addSkip(test, reason)

    def addFailure(self, test, err):
        self._record(test, "failure")
        super().addFailure(test, err)

    def addError(self, test, err):
        self._record(test, "error")
        super().addError(test, err)

    def addExpectedFailure(self, test, err):
        self._record(test, "expected failure")
        super().addExpectedFailure(test, err)

    def addUnexpectedSuccess(self, test):
        self._record(test, "unexpected success")
        super().addUnexpectedSuccess(test)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            self._record(test, "failure" if issubclass(err[0], test.failureException) else "error")
        super().addSubTest(test, subtest, err)

    def observation(self) -> dict:
        return {
            "executions": self.executions,
            "ran_reported": self.testsRun,
            "skipped_reported": len(self.skipped),
            "failures_reported": len(self.failures),
            "errors_reported": len(self.errors),
            "expected_failures_reported": len(self.expectedFailures),
            "unexpected_successes_reported": len(self.unexpectedSuccesses),
            "successful": self.wasSuccessful(),
        }


def judge(roster: dict, collected: dict, observed: dict) -> list[str]:
    """Require exact full identities, a closed denominator, and actual successful outcomes."""
    problems: list[str] = []
    expected = set(collected["ids"])
    internal = set(roster["internal"])
    excluded = {entry["id"] for entry in roster["excluded"]}
    if not expected or len(expected) != collected["total"]:
        problems.append("discovery is empty or carries duplicate test identities")
    if internal & excluded or internal | excluded != expected:
        problems.append("internal and historical rosters do not partition discovery exactly")

    rows = observed.get("executions", [])
    identities = [row.get("id") for row in rows]
    present = set(identities)
    if len(present) != len(identities):
        problems.append("duplicate test executions")
    missing = expected - present
    unexpected = present - expected
    if missing:
        problems.append(f"discovered tests did not execute: {sorted(missing)}")
    if unexpected:
        problems.append(f"unexpected executed test identities: {sorted(unexpected, key=str)}")
    if observed.get("ran_reported") != collected["total"] or len(rows) != collected["total"]:
        problems.append("execution denominator does not match discovery")

    counts = {"skipped": 0, "failure": 0, "error": 0, "expected failure": 0, "unexpected success": 0}
    for row in rows:
        outcome = row.get("outcome")
        test_id = row.get("id")
        if outcome in counts:
            counts[outcome] += 1
        if outcome == "skipped":
            if test_id not in excluded:
                problems.append(f"INTERNAL test SKIPPED: {test_id}")
        elif outcome != "ok":
            problems.append(f"test did not pass: {test_id}: {outcome}")
        if row.get("failures", 0) or row.get("errors", 0):
            problems.append(f"recorded failure or error: {test_id}")

    reported = {
        "skipped": counts["skipped"],
        "failure": sum(row.get("failures", 0) for row in rows),
        "error": sum(row.get("errors", 0) for row in rows),
        "expected failure": counts["expected failure"],
        "unexpected success": counts["unexpected success"],
    }
    for outcome, field in (
        ("skipped", "skipped_reported"),
        ("failure", "failures_reported"),
        ("error", "errors_reported"),
        ("expected failure", "expected_failures_reported"),
        ("unexpected success", "unexpected_successes_reported"),
    ):
        if observed.get(field) != reported[outcome]:
            problems.append(f"{outcome} count does not match recorded outcomes")
    if observed.get("successful") is not True:
        problems.append("the unittest runner did not finish successfully")
    return problems


def _result_path(log_path: Path) -> Path:
    return log_path.with_name(log_path.name + ".results.json")


def execute_suite(suite: unittest.TestSuite, log_path: Path, collected: dict, stream=None) -> int:
    """Execute the real suite and retain raw output plus a digest-bound lifecycle report."""
    with contextlib.ExitStack() as stack:
        if stream is None:
            stream = stack.enter_context(log_path.open("w", encoding="utf-8"))
        stack.enter_context(contextlib.redirect_stdout(stream))
        stack.enter_context(contextlib.redirect_stderr(stream))
        result = unittest.TextTestRunner(stream=stream, verbosity=2, resultclass=RecordedResult).run(suite)
        stream.flush()
    raw = log_path.read_bytes()
    report = {
        "kind": "readiness-suite-result",
        "schema": 1,
        "collected": collected,
        "observed": result.observation(),
        "raw_log": {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)},
    }
    _result_path(log_path).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if result.wasSuccessful() else 1


def load_report(log_path: Path) -> dict:
    report = json.loads(_result_path(log_path).read_text(encoding="utf-8"))
    if report.get("kind") != "readiness-suite-result" or report.get("schema") != 1:
        raise ValueError("unsupported readiness result report")
    raw = log_path.read_bytes()
    if report.get("raw_log") != {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}:
        raise ValueError("readiness raw log does not match its result report")
    return report


def _outside_repository(path: str | Path) -> Path:
    resolved = Path(path).resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        raise ValueError(f"readiness output must be outside the repository: {resolved}")
    return resolved


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="source-derived readiness roster with recorded unittest outcomes")
    ap.add_argument("--log", help="raw log to create with --run, or replay with its result sidecar")
    ap.add_argument("--run", action="store_true", help="execute the complete discovered suite")
    ap.add_argument("--roster", help="write the derived roster and observed outcomes outside the repository")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--execute-suite", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))

    try:
        if args.execute_suite:
            log_path = _outside_repository(args.execute_suite)
            suite = unittest.TestLoader().discover(str(TESTS))
            return execute_suite(suite, log_path, collect_test_ids(suite), stream=sys.stderr)
        if not args.run and not args.log:
            ap.error("one of --run or --log is required")
        if args.log:
            log_path = _outside_repository(args.log)
        else:
            directory = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / "board1-readiness"
            directory.mkdir(parents=True, exist_ok=True)
            fd, name = tempfile.mkstemp(prefix="readiness-", suffix=".log", dir=directory)
            os.close(fd)
            log_path = _outside_repository(name)
        roster_path = _outside_repository(args.roster) if args.roster else None
        if roster_path in (log_path, _result_path(log_path)):
            raise ValueError("roster output must not overwrite the raw log or its result report")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        proc_rc = 0
        if args.run:
            try:
                with log_path.open("w", encoding="utf-8") as stream:
                    proc = subprocess.run(
                        [sys.executable, str(Path(__file__).resolve()), "--execute-suite", str(log_path)],
                        cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=3600)
                proc_rc = proc.returncode
            except subprocess.TimeoutExpired:
                print(f"::error::readiness execution timed out; retained raw log: {log_path}", file=sys.stderr)
                return 1
        report = load_report(log_path)
        collected = collect_test_ids()
        roster = derive_roster(collected["ids"], ROOT / "tools" / "readiness")
        observed = report["observed"]
        problems = judge(roster, collected, observed)
        if report["collected"] != collected:
            problems.append("recorded discovery differs from the current source population")
        if proc_rc != 0:
            problems.append(f"test runner exited with non-zero status: {proc_rc}")
        if roster_path:
            roster_path.write_text(json.dumps({
                **roster, "collected": collected, "observed": observed,
                "raw_log": report["raw_log"], "problems": problems,
            }, indent=2) + "\n", encoding="utf-8")
        if args.json:
            print(json.dumps({"roster": roster, "observed": observed, "problems": problems}, indent=2))
        counts = roster["counts"]
        print(f"readiness roster: collected {collected['total']} | internal required "
              f"{counts['internal_required']} | historical excluded {counts['excluded_historical']}")
        print(f"raw log: {log_path}; recorded results: {_result_path(log_path)}")
        if problems:
            for problem in problems:
                print(f"::error::{problem}")
            return 1
        print("readiness roster: PASSED (exact identities; zero internal skips or nonpassing outcomes)")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"::error::readiness result refused: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
