"""*** THE MUTATION HARNESS: RESTORE UNCONDITIONALLY, JUDGE AFTERWARDS. ***

*WHY THIS EXISTS AS A SHARED MODULE RATHER THAN A SHELL IDIOM: **MY FIRST HARNESS RAN UNDER `set -e` WHILE THE ARM
FAILING IS THE PASS CONDITION.** So when `xcodebuild` returned non-zero -- the mutation WORKING -- the script aborted
BEFORE ITS OWN RESTORE STEP.* ***THE CONSEQUENCE IS TWO-SIDED AND BOTH SIDES ARE BAD: the tree could be left carrying
a deliberately-broken production line, AND the run could never record "KILLED", because it died on the exact result it
was looking for.***

**SO THE ORDER IS FIXED HERE, ONCE:** *snapshot the target; apply the mutation; assert it actually changed something;
build and run; **restore UNCONDITIONALLY, in a `finally`**; verify the tree is byte-clean against HEAD; and only THEN
judge the captured result.* *A mutation whose cleanup is conditional on its own success is not a mutation harness -- it
is a way to leave the tree broken.*

*** AND A NO-OP IS REFUSED RATHER THAN COUNTED. *** *An anchor that matches nothing leaveth the source unchanged, so
the "mutated" run would test the UNMUTATED tree and report whatever it reported -- **and a mutation that cannot be
applied is not a killed mutation; it is an experiment that proved nothing.*** *This project has already lost a cycle to
exactly that, so the harness asserteth the change rather than assuming it.*
"""
from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git(*args: str) -> tuple[int, str]:
    proc = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, timeout=300)
    return proc.returncode, proc.stdout.strip()


def builders_running() -> int:
    """*** A CONCURRENT BUILD INVALIDATES A RUN: the tests can execute against a tree the sources no longer describe. ***

    *`pgrep -fc` printeth NOTHING when there are no matches, so a bare `|| echo 0` yieldeth `"0\\n0"` and a numeric
    comparison againſt that failét -- which is how my own guard once aborted a run it was meant to protect.* **The
    empty output is normalised HERE, once.**
    """
    proc = subprocess.run(["pgrep", "-fc", "xcodebuild|swift-test"], capture_output=True, text=True)
    text = (proc.stdout or "").strip()
    return int(text) if text.isdigit() else 0


class Mutation:
    """*A single deliberate break, with its restore guaranteed.*"""

    def __init__(self, target: Path, label: str) -> None:
        self.target = target.resolve()
        self.label = label
        self.relpath = str(self.target.relative_to(REPO))
        self.original: bytes | None = None
        self.killed = False
        self.restored_clean = False
        self.test_returncode: int | None = None
        self.note = ""

    def __enter__(self) -> "Mutation":
        if builders_running():
            raise RuntimeError("refusing to start: a build is already running, and a concurrent build invalidates the run")
        rc, _ = _git("diff", "--quiet", "HEAD", "--", self.relpath)
        if rc != 0:
            raise RuntimeError(f"{self.relpath} is DIRTY before the mutation -- the experiment would start from an "
                               f"unknown tree, so its result could not be attributed to the mutation")
        self.original = self.target.read_bytes()
        return self

    def apply(self, replacement: str, *, old: str) -> None:
        """*** APPLY BY EXACT ANCHOR, AND REFUSE A NO-OP LOUDLY. ***"""
        text = self.target.read_text(encoding="utf-8")
        count = text.count(old)
        if count != 1:
            raise RuntimeError(f"the mutation anchor occurreth {count} times; it must occur exactly once")
        self.target.write_text(text.replace(old, replacement), encoding="utf-8")
        if sha256_of(self.target) == hashlib.sha256(self.original).hexdigest():
            raise RuntimeError("the mutation did not change the file -- a no-op is not an experiment")

    def record(self, returncode: int, *, killed_when: bool, note: str = "") -> None:
        self.test_returncode = returncode
        self.killed = killed_when
        self.note = note

    def __exit__(self, *exc) -> bool:
        # *** UNCONDITIONAL. THIS IS THE WHOLE POINT OF THE MODULE. ***
        if self.original is not None:
            self.target.write_bytes(self.original)
        rc, _ = _git("diff", "--quiet", "HEAD", "--", self.relpath)
        self.restored_clean = (rc == 0) and (sha256_of(self.target) == hashlib.sha256(self.original or b"").hexdigest())
        return False   # never swallow an exception; the restore happened, and the caller still sees the failure

    def row(self) -> str:
        verdict = "KILLED" if self.killed else "ESCAPED"
        clean = "clean" if self.restored_clean else "*** TREE DIRTY ***"
        return f"{self.label}: {verdict} (rc={self.test_returncode}, {clean}){(' -- ' + self.note) if self.note else ''}"
