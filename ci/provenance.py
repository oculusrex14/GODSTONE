#!/usr/bin/env python3
"""Bind verification evidence to a clean commit (ADR-008 Stage 3, Phase A3).

Every verification runner must prove the evidence it produces came from a
CLEAN checkout of a named commit, not a dirty worktree. A dirty tree can
silently include uncommitted edits that change behaviour, so evidence drawn
from one is diagnostic only and must never be classified as release/commit
evidence.

Usage (run once right after checkout, and again as the FINAL step of the job):

    python ci/provenance.py [--out provenance.json]

It records:
  git rev-parse HEAD            -> commit SHA
  git rev-parse HEAD^{tree}     -> tree SHA
  git status --porcelain        -> must be empty
  git diff --check              -> must be clean (whitespace errors fail)

and the toolchain matrix:
  repository, branch, commit SHA, tree SHA, workflow run id, runner OS,
  JDK, Gradle, AGP, Kotlin, Android SDK, NDK, CMake, Xcode, Swift, xcodegen.

Exits 1 if `git status --porcelain` is non-empty OR `git diff --check` reports
whitespace errors, so a dirty tree fails the job rather than producing
unclassified evidence. Missing toolchains are recorded as null (a runner that
has no Xcode records null, not a false value).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _git(args: list[str]) -> str:
    p = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else p.stdout.strip()


def _tool(args: list[str]) -> str | None:
    """Best-effort version string for a tool; None if unavailable."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=20)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None
    if p.returncode != 0 and not p.stdout:
        return None
    out = (p.stdout or p.stderr).strip()
    # Keep only the first line for compactness.
    return out.splitlines()[0] if out else None


def _detect_matrix() -> dict[str, str | None]:
    """Detect installed toolchain versions. None where the tool is absent."""
    matrix: dict[str, str | None] = {}

    # JDK
    java = _tool(["java", "-version"])
    # java -version writes to stderr; _tool already folds stderr in.
    matrix["jdk"] = java

    # Gradle (use the committed wrapper so the version is the pinned one).
    gradle = _tool(["sh", "-c", "cd android 2>/dev/null && ./gradlew --version "
                              "--no-daemon 2>/dev/null | grep -E '^Gradle '"])
    matrix["gradle"] = gradle

    # AGP / Kotlin are read from the Gradle build files rather than shelling,
    # because they are not standalone CLIs. Resolve lazily; null if absent.
    agp = None
    kotlin = None
    for kts in (ROOT / "android").rglob("build.gradle.kts"):
        try:
            text = kts.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if agp is None:
            m = __import__("re").search(r"com\.android\.tools\.build:gradle:(\d+\.\d+(?:\.\d+)?)", text)
            if m:
                agp = m.group(1)
        if kotlin is None:
            m = __import__("re").search(r'kotlin\s*=\s*"(\d+\.\d+(?:\.\d+)?)"', text)
            if m:
                kotlin = m.group(1)
    matrix["agp"] = agp
    matrix["kotlin"] = kotlin

    # Android SDK / NDK / CMake (sdkmanager / ndk-build / cmake)
    matrix["android_sdk"] = (
        os.environ.get("ANDROID_HOME")
        or os.environ.get("ANDROID_SDK_ROOT")
        or None
    )
    matrix["ndk"] = _tool(["ndk-build", "--version"]) or None
    matrix["cmake"] = _tool(["cmake", "--version"])

    # Apple toolchain
    matrix["xcode"] = _tool(["xcodebuild", "-version"])
    matrix["swift"] = _tool(["swift", "--version"])
    matrix["xcodegen"] = _tool(["xcodegen", "--version"])

    return matrix


def record(out: Path) -> int:
    head = _git(["rev-parse", "HEAD"]) or None
    tree = _git(["rev-parse", "HEAD^{tree}"]) or None
    status = _git(["status", "--porcelain"])
    diff_check = subprocess.run(
        ["git", "diff", "--check"], cwd=ROOT, capture_output=True, text=True
    )
    diff_check_out = diff_check.stdout.strip()

    provenance = {
        "repository": os.environ.get("GITHUB_REPOSITORY") or str(ROOT),
        "branch": os.environ.get("GITHUB_REF_NAME")
        or _git(["rev-parse", "--abbrev-ref", "HEAD"]) or None,
        "commit_sha": head,
        "tree_sha": tree,
        "workflow_run_id": os.environ.get("GITHUB_RUN_ID") or None,
        "runner_os": os.environ.get("RUNNER_OS") or None,
        "git_status_porcelain": status,
        "git_diff_check": diff_check_out,
        "clean": (not status) and (not diff_check_out),
        "toolchain": _detect_matrix(),
    }

    print("== verification provenance ==")
    for k in ("repository", "branch", "commit_sha", "tree_sha",
              "workflow_run_id", "runner_os"):
        print(f"  {k:18} {provenance[k]}")
    print(f"  git status --porcelain:\n{_indent(status)}")
    print(f"  git diff --check:\n{_indent(diff_check_out)}")
    print("  toolchain:")
    for k, v in provenance["toolchain"].items():
        print(f"    {k:11} {v}")

    out.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n",
                   encoding="utf-8")
    print(f"  provenance written: {out}")

    if status:
        print("::error::working tree is dirty (git status --porcelain non-empty) "
              "-- evidence from a dirty tree is diagnostic only, not commit "
              "evidence. Commit or discard the changes before claiming evidence.")
        return 1
    if diff_check_out:
        print("::error::git diff --check reports whitespace errors -- commit is "
              "not clean.")
        return 1
    print("ok: clean commit provenance recorded")
    return 0


def _indent(text: str) -> str:
    if not text:
        return "    (empty)"
    return "\n".join("    " + line for line in text.splitlines())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path,
                    default=Path("provenance.json"),
                    help="path to write the provenance JSON manifest")
    args = ap.parse_args()
    return record(args.out)


if __name__ == "__main__":
    raise SystemExit(main())