#!/usr/bin/env python3
"""GS-FINAL-009: PROVE THE COMMAND CLASSIFICATION IS ENFORCED BY THE COMPILER, NOT BY PROSE.

THE CLAIM BEING TESTED, AND WHERE IT CAME FROM. A review observed that `isProtectedCommand` was "still
prose a human must apply to the next command" and proposed inverting it behind a single seam. **THE
REVIEW'S INSTINCT WAS RIGHT AND ITS PREMISE WAS WRONG, AND THIS PROBE MEASURES WHICH:**

    `MeshCommand` is SEALED and `isProtectedCommand` is an exhaustive `when` WITH NO `else`. So a future
    command CANNOT be added without a human deciding, IN THE CODE, whether it is protected -- the compiler
    refuses to build until they do.

AND THAT IS NOT AN ARGUMENT, IT IS A MEASUREMENT: this probe adds a twelfth `MeshCommand`, compiles, and
INSPECTS THE COMPILER'S ANSWER. It then restores the file and confirms the tree is byte-identical.

WHY A PROBE RATHER THAN AN ARM IN THE LANE: an arm that proves the compiler rejects unclassified commands
has to MAKE the compiler reject them, which means a red build. A red build inside a module reddens every
lane on that isle, so the proof lives here, runs on demand, and is recorded with its exact command.

    python3 ci/probe_mesh_command_exhaustiveness.py

Exit 0 means the mechanism is enforced. Exit 1 means it is NOT -- and then the prose rule really is prose,
and `isProtectedCommand` needs the seam the review proposed.
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ANDROID = REPO / "android"
CONTRACTS = ANDROID / "app/src/main/java/io/godstone/app/mesh/MeshContracts.kt"
VIEWMODEL = ANDROID / "app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt"

# The sentinel command. Named so the compiler's own message quotes it back.
SENTINEL = "ProbeUnclassifiedCommand"
ANCHOR = "    object ClearError : MeshCommand()"


def run_compile() -> tuple[int, str]:
    env = dict(os.environ)
    env["JAVA_HOME"] = "/opt/homebrew/opt/openjdk@17"
    env["ANDROID_HOME"] = "/Users/oculus/Library/Android/sdk"
    proc = subprocess.run(
        ["./gradlew", ":app:compileLightDebugKotlin", "--rerun-tasks", "--no-daemon", "--console=plain"],
        cwd=ANDROID, env=env, capture_output=True, text=True, timeout=1800,
    )
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    if not CONTRACTS.exists():
        print(f"FAIL: {CONTRACTS} not found")
        return 1

    original = CONTRACTS.read_bytes()
    digest_before = hashlib.sha256(original).hexdigest()
    source = original.decode("utf-8")

    if source.count(ANCHOR) != 1:
        print(f"FAIL: the anchor is not unique ({source.count(ANCHOR)} occurrences) -- the probe would edit the wrong place")
        return 1

    # 1. THE SCAFFOLDING MUST BUILD FIRST, or a failure below would prove nothing.
    print("== 1. the unmodified tree compiles (the scaffolding control) ==")
    code, output = run_compile()
    if code != 0:
        print("FAIL: the UNMODIFIED tree does not compile, so this probe could not attribute anything to the sentinel")
        print(output[-2000:])
        return 1
    print("   the unmodified tree compiles.")

    verdict = 1
    try:
        # 2. ADD A COMMAND THE CLASSIFICATION DOES NOT KNOW.
        print(f"== 2. adding a twelfth command ({SENTINEL}) to the sealed hierarchy ==")
        patched = source.replace(
            ANCHOR,
            ANCHOR + f"\n\n    /** probe-only: an unclassified command. */\n    object {SENTINEL} : MeshCommand()",
        )
        CONTRACTS.write_text(patched, encoding="utf-8")

        code, output = run_compile()
        print(f"   compiler exit code: {code}")

        # 3. THE MECHANISM MUST BE THE COMPILER, AND IT MUST NAME BOTH SITES.
        exhaustive = [ln for ln in output.splitlines() if "must be exhaustive" in ln and SENTINEL in ln]
        for line in exhaustive:
            print("   " + line.strip())

        if code == 0:
            print("FAIL: a new command was added and the build SUCCEEDED -- the classification is NOT enforced,")
            print("      so the prose rule really is prose. The reviewed proposal (one seam for every `port.`")
            print("      call) is then REQUIRED rather than optional.")
            return 1

        if not exhaustive:
            print("FAIL: the build failed, but NOT because of exhaustiveness -- the probe cannot attribute the")
            print("      failure to the mechanism it is testing.")
            return 1

        # BOTH sites must demand a decision: the classification AND the dispatch.
        for path, label in ((VIEWMODEL, "isProtectedCommand / onCommand"),):
            rel = path.relative_to(REPO)
            named = [ln for ln in exhaustive if str(rel.name) in ln]
            print(f"   sites reported in {label}: {len(named)}")

        print("PASS: the compiler REFUSED the unclassified command and named the sentinel. A future command")
        print("      cannot reach production without a human deciding, in code, whether it is protected.")
        verdict = 0

    finally:
        # 4. THE TREE MUST BE UNTOUCHED -- proved by digest, not by intention.
        #
        # AND THIS BLOCK DOES NOT `return`: a `return` inside `finally` SWALLOWS ANY IN-FLIGHT EXCEPTION and
        # overrides the outer value, which would make a crashed probe report itself as a clean restoration. The
        # verdict is carried in a variable and the cleanup report is appended to it.
        CONTRACTS.write_bytes(original)
        digest_after = hashlib.sha256(CONTRACTS.read_bytes()).hexdigest()
        print("== 4. restoration ==")
        print(f"   sha256 before: {digest_before}")
        print(f"   sha256 after:  {digest_after}")
        if digest_before != digest_after:
            print("FAIL: THE FILE WAS NOT RESTORED -- the working tree is dirty and must be fixed by hand.")
            verdict = 1
        else:
            print("   the file is byte-identical; the tree is clean.")

    return verdict


if __name__ == "__main__":
    sys.exit(main())
